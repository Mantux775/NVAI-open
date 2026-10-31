// Decoder of the LTX-Video VAE (Lightricks "CausalVideoAutoencoder", 0.9.x with timestep conditioning): 128 latent
// channels, 32 × 32 × 8 compression. conv_in 128 → 1024, then four groups of five residual blocks (1024, 512, 256,
// 128 channels) with three depth-to-space upsamplers (×2 in time, height and width, residual) between them, pixel
// norm, conv_out to 48 channels and a 4 × 4 unpatchify. The decoder is not causal: each 3 × 3 × 3 conv pads one frame
// on both sides by repeating the edge frame and pads height and width by reflection.
//
// Layout here is channels-last, [B, F, H, W, C]. Pixel norm has no cross-position statistics, so the last stage
// (upsampler to 128 channels, five residual blocks, conv_out) can run on spatial tiles with enough context and give
// the same result as one pass (`decode(tile:)`): a conv pads only at the frame's real edges.

import Foundation
import MLX
import MLXFast
import MLXNN

public struct LTXDecoderConfiguration: Sendable {
    public var latentChannels = 128
    public var channels = [1024, 512, 256, 128]
    public var layersPerGroup = 5
    public var patchSize = 4
    public init() {}
}

/// Which spatial sides of a piece are the frame's real edges (padded by reflection); the others carry context.
struct Edges: Equatable {
    var top = true, bottom = true, left = true, right = true
    static let all = Edges()
    /// Pixels a conv eats away per unpadded side.
    var unpadded: (top: Int, bottom: Int, left: Int, right: Int) {
        (top ? 0 : 1, bottom ? 0 : 1, left ? 0 : 1, right ? 0 : 1)
    }
}

/// 3 × 3 × 3 conv with the decoder's padding: edge frame repeated in time, reflection in space at real edges.
final class VideoConv: Module {
    @ModuleInfo var conv: Conv3d

    init(_ inC: Int, _ outC: Int) {
        _conv.wrappedValue = Conv3d(inputChannels: inC, outputChannels: outC, kernelSize: 3, stride: 1, padding: 0)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, edges: Edges = .all) -> MLXArray {
        let f = x.dim(1)
        var h = concatenated([x[0..., 0 ..< 1], x, x[0..., (f - 1) ..< f]], axis: 1)
        let hh = h.dim(2), ww = h.dim(3)
        var rows: [MLXArray] = []
        if edges.top { rows.append(h[0..., 0..., 1 ..< 2]) }
        rows.append(h)
        if edges.bottom { rows.append(h[0..., 0..., (hh - 2) ..< (hh - 1)]) }
        if rows.count > 1 { h = concatenated(rows, axis: 2) }
        var cols: [MLXArray] = []
        if edges.left { cols.append(h[0..., 0..., 0..., 1 ..< 2]) }
        cols.append(h)
        if edges.right { cols.append(h[0..., 0..., 0..., (ww - 2) ..< (ww - 1)]) }
        if cols.count > 1 { h = concatenated(cols, axis: 3) }
        return conv(h)
    }
}

func pixelNorm(_ x: MLXArray, eps: Float = 1e-8) -> MLXArray {
    x * rsqrt(mean(x * x, axis: -1, keepDims: true) + eps)
}

/// Crop `n` pixels from each unpadded side of a channels-last tensor.
func cropUnpadded(_ x: MLXArray, _ edges: Edges, by n: Int) -> MLXArray {
    if edges == .all || n == 0 { return x }
    let u = edges.unpadded
    let h = x.dim(2), w = x.dim(3)
    return x[0..., 0..., (u.top * n) ..< (h - u.bottom * n), (u.left * n) ..< (w - u.right * n)]
}

final class DecoderResBlock: Module {
    @ModuleInfo var conv1: VideoConv
    @ModuleInfo var conv2: VideoConv
    @ParameterInfo(key: "scale_shift_table") var scaleShiftTable: MLXArray

    init(_ c: Int) {
        _conv1.wrappedValue = VideoConv(c, c)
        _conv2.wrappedValue = VideoConv(c, c)
        _scaleShiftTable.wrappedValue = MLXArray.zeros([4, c])
        super.init()
    }

    /// `emb`: [4, C] timestep values of this group (shift1, scale1, shift2, scale2).
    func callAsFunction(_ x: MLXArray, emb: MLXArray, edges: Edges) -> MLXArray {
        let m = scaleShiftTable.asType(x.dtype) + emb.asType(x.dtype)
        var h = pixelNorm(x) * (1 + m[1]) + m[0]
        h = conv1(silu(h), edges: edges)
        h = pixelNorm(h) * (1 + m[3]) + m[2]
        h = conv2(silu(h), edges: edges)
        return cropUnpadded(x, edges, by: 2) + h
    }
}

final class DecoderResGroup: Module {
    @ModuleInfo(key: "res_blocks") var resBlocks: [DecoderResBlock]
    @ModuleInfo(key: "time_embedder") var timeEmbedder: CombinedTimestepEmbedder
    let channels: Int

    init(_ c: Int, layers: Int) {
        channels = c
        _resBlocks.wrappedValue = (0 ..< layers).map { _ in DecoderResBlock(c) }
        _timeEmbedder.wrappedValue = CombinedTimestepEmbedder(4 * c)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, emb: MLXArray, edges: Edges) -> MLXArray {
        var h = x
        for block in resBlocks { h = block(h, emb: emb, edges: edges) }
        return h
    }
}

/// Conv to 8 × out channels, then depth-to-space ×2 in time, height and width; the first frame is dropped (the time
/// axis is causal: latent frame 0 stands for one frame). Residual: the input rearranged the same way, its channels
/// repeated to match.
final class DepthToSpaceUpsample: Module {
    @ModuleInfo var conv: VideoConv
    let outChannels: Int

    init(_ inC: Int, reduction: Int = 2) {
        outChannels = inC / reduction
        _conv.wrappedValue = VideoConv(inC, 8 * inC / reduction)
        super.init()
    }

    static func depthToSpace(_ x: MLXArray) -> MLXArray {
        let b = x.dim(0), f = x.dim(1), h = x.dim(2), w = x.dim(3), c = x.dim(4) / 8
        return x.reshaped(b, f, h, w, c, 2, 2, 2)
            .transposed(0, 1, 5, 2, 6, 3, 7, 4)
            .reshaped(b, f * 2, h * 2, w * 2, c)
    }

    func callAsFunction(_ x: MLXArray, edges: Edges) -> MLXArray {
        let y = Self.depthToSpace(conv(x, edges: edges))
        var residual = Self.depthToSpace(cropUnpadded(x, edges, by: 1))
        residual = tiled(residual, repetitions: [1, 1, 1, 1, outChannels / residual.dim(4)])
        return y[0..., 1...] + residual[0..., 1...]
    }
}

public final class LTXVideoDecoder: Module {
    @ModuleInfo(key: "conv_in") var convIn: VideoConv
    @ModuleInfo(key: "up_blocks") var upBlocks: [Module]
    @ModuleInfo(key: "conv_out") var convOut: VideoConv
    @ModuleInfo(key: "last_time_embedder") var lastTimeEmbedder: CombinedTimestepEmbedder
    @ParameterInfo(key: "last_scale_shift_table") var lastScaleShiftTable: MLXArray
    @ParameterInfo(key: "timestep_scale_multiplier") var timestepScaleMultiplier: MLXArray
    /// Per-channel latent statistics (`per_channel_statistics`); set by the loader. A plain class, so the module
    /// does not count them among its parameters.
    public final class Statistics {
        public var mean = MLXArray.zeros([128])
        public var std = MLXArray.ones([128])
    }
    public let statistics = Statistics()
    public let config: LTXDecoderConfiguration

    public init(_ c: LTXDecoderConfiguration = LTXDecoderConfiguration()) {
        config = c
        _convIn.wrappedValue = VideoConv(c.latentChannels, c.channels[0])
        var blocks: [Module] = []
        for (i, ch) in c.channels.enumerated() {
            blocks.append(DecoderResGroup(ch, layers: c.layersPerGroup))
            if i < c.channels.count - 1 { blocks.append(DepthToSpaceUpsample(ch)) }
        }
        _upBlocks.wrappedValue = blocks
        _convOut.wrappedValue = VideoConv(c.channels.last!, 3 * c.patchSize * c.patchSize)
        _lastTimeEmbedder.wrappedValue = CombinedTimestepEmbedder(2 * c.channels.last!)
        _lastScaleShiftTable.wrappedValue = MLXArray.zeros([2, c.channels.last!])
        _timestepScaleMultiplier.wrappedValue = MLXArray(Float(1000))
        super.init()
    }

    /// Frames out for `latentFrames` in: 8·F − 7.
    public static func outputFrames(_ latentFrames: Int) -> Int { 8 * latentFrames - 7 }

    /// 4 × 4 unpatchify: channel c·16 + r·4 + q → pixel (y·4 + q, x·4 + r) of channel c.
    func unpatchify(_ x: MLXArray) -> MLXArray {
        let b = x.dim(0), f = x.dim(1), h = x.dim(2), w = x.dim(3), p = config.patchSize
        return x.reshaped(b, f, h, w, 3, p, p)          // c, r, q
            .transposed(0, 1, 2, 6, 3, 5, 4)             // b f h q w r c
            .reshaped(b, f, h * p, w * p, 3)
    }

    /// Timestep values of every residual group and of the final norm for decode timestep `t`.
    func timestepValues(_ t: Float, dtype: DType) -> (groups: [MLXArray], last: MLXArray) {
        let scaled = t * timestepScaleMultiplier.asType(.float32).item(Float.self)
        var groups: [MLXArray] = []
        for case let group as DecoderResGroup in upBlocks {
            groups.append(group.timeEmbedder(scaled, dtype: dtype).reshaped(4, group.channels))
        }
        let last = lastTimeEmbedder(scaled, dtype: dtype).reshaped(2, config.channels.last!)
        return (groups, last)
    }

    /// Denormalized channels-last latents: noise mixed in first (x · (1 − s) + n · s), then the tone map (13B), then
    /// the channel statistics – the order of Lightricks' pipeline.
    func prepare(_ latents: MLXArray, noise: MLXArray?, noiseScale: Float, toneMap: Float = 0) -> MLXArray {
        var z = latents.asType(.float32)
        if let noise { z = z * (1 - noiseScale) + noise.asType(.float32) * noiseScale }
        if toneMap > 0 { z = LTXPipeline.toneMap(z, compression: toneMap) }
        let shape = [1, -1, 1, 1, 1]
        z = z * statistics.std.asType(.float32).reshaped(shape) + statistics.mean.asType(.float32).reshaped(shape)
        return z.transposed(0, 2, 3, 4, 1)
    }

    /// The last stage: upsampler to 128 channels, five residual blocks, norm, conv_out, unpatchify.
    func lastStage(_ x: MLXArray, _ values: (groups: [MLXArray], last: MLXArray), edges: Edges) -> MLXArray {
        let up = upBlocks[upBlocks.count - 2] as! DepthToSpaceUpsample
        let group = upBlocks[upBlocks.count - 1] as! DecoderResGroup
        var h = group(up(x, edges: edges), emb: values.groups[values.groups.count - 1], edges: edges)
        let m = lastScaleShiftTable.asType(h.dtype) + values.last.asType(h.dtype)
        h = pixelNorm(h) * (1 + m[1]) + m[0]
        return convOut(silu(h), edges: edges)
    }

    /// Model latents [B, 128, F, H, W] (NCHW, as the transformer side keeps them) → video [B, 8F − 7, 32H, 32W, 3]
    /// in [−1, 1]. `noise` [same shape] is mixed in with `noiseScale` (the reference: 0.025 at decode timestep 0.05).
    /// `tile` > 0 runs the last stage in tiles of that many pixels at quarter resolution (e.g. 32 → 256 px), with
    /// 7 pixels of context per inner side, which is exactly what its 12 convs reach (identical to one pass).
    public func decode(_ latents: MLXArray, timestep: Float = 0.05, noise: MLXArray? = nil, noiseScale: Float = 0.025,
                       toneMap: Float = 0, dtype: DType = .float32, tile: Int = 0,
                       onTile: ((Int, Int) -> Void)? = nil) -> MLXArray {
        let values = timestepValues(timestep, dtype: dtype)
        var x = convIn(prepare(latents, noise: noise, noiseScale: noiseScale, toneMap: toneMap).asType(dtype))
        for block in upBlocks.dropLast(2) {
            if let res = block as? DecoderResGroup {
                let index = upBlocks.firstIndex { $0 === res }!
                x = res(x, emb: values.groups[index / 2], edges: .all)
            } else if let up = block as? DepthToSpaceUpsample {
                x = up(x, edges: .all)
            }
            eval(x)
        }
        let h4 = x.dim(2), w4 = x.dim(3)
        if tile <= 0 || (h4 <= tile && w4 <= tile) {
            let out = unpatchify(lastStage(x, values, edges: .all))
            eval(out)
            return out
        }
        // Tiles at quarter resolution; each output pixel row/column comes from exactly one tile.
        let context = 7
        func spans(_ n: Int) -> [Range<Int>] {
            stride(from: 0, to: n, by: tile).map { $0 ..< min($0 + tile, n) }
        }
        let rows = spans(h4), cols = spans(w4)
        var bands: [MLXArray] = []
        var done = 0
        for r in rows {
            var pieces: [MLXArray] = []
            for c in cols {
                let y0 = max(0, r.lowerBound - context), y1 = min(h4, r.upperBound + context)
                let x0 = max(0, c.lowerBound - context), x1 = min(w4, c.upperBound + context)
                let edges = Edges(top: y0 == 0, bottom: y1 == h4, left: x0 == 0, right: x1 == w4)
                var out = lastStage(x[0..., 0..., y0 ..< y1, x0 ..< x1], values, edges: edges)
                // An inner side loses 13 pixels at stage resolution (2 by the upsampler conv, 10 by the residual
                // convs, 1 by conv_out) of its 2 × 7 context, leaving one; a real edge is padded and loses none.
                let top = 2 * (r.lowerBound - y0) - (y0 > 0 ? 13 : 0)
                let left = 2 * (c.lowerBound - x0) - (x0 > 0 ? 13 : 0)
                out = out[0..., 0..., top ..< (top + 2 * r.count), left ..< (left + 2 * c.count)]
                let piece = unpatchify(out)
                eval(piece)
                pieces.append(piece)
                Memory.clearCache()
                done += 1
                onTile?(done, rows.count * cols.count)
            }
            bands.append(concatenated(pieces, axis: 3))
        }
        let out = concatenated(bands, axis: 2)
        eval(out)
        return out
    }
}
