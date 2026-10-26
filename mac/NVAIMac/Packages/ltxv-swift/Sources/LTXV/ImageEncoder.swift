// Encoder of the LTX-Video VAE for one start image (image to video). The encoder is causal in time: every 3D
// convolution pads the clip with copies of its first frame. For a clip of one frame each convolution therefore sees
// the same frame three times, which equals a 2D convolution whose kernel is the 3D kernel summed over time; and every
// downsampler with a time stride of 2 sees the frame twice. So the whole encoder runs as 2D convolutions on
// [1, H, W, C], with the summed kernels stored once (`LTXWeights.convertImageEncoder`, a third of the size).
//
// Layout of ltxv-2b-0.9.8 (config `encoder_blocks`): patchify 4 × 4 → conv_in → res_x ×4 → compress_space_res →
// res_x ×6 → compress_time_res → res_x ×6 → compress_all_res → res_x ×2 → compress_all_res → res_x ×2 → pixel norm →
// SiLU → conv_out (128 means + 1 log variance). The means are normalized with the VAE's per-channel statistics.

import Foundation
import MLX
import MLXNN

public final class LTXImageEncoder {
    public enum Block: Equatable, Sendable {
        case res(layers: Int)
        /// Space-to-depth downsampler with a residual: stride in (time, height, width), output channels × multiplier.
        case down(t: Int, h: Int, w: Int, multiplier: Int)
    }

    /// Blocks of LTX-Video 0.9.5 to 0.9.8 (2B and 13B use the same VAE).
    public static let defaultBlocks: [Block] = [
        .res(layers: 4), .down(t: 1, h: 2, w: 2, multiplier: 2), .res(layers: 6), .down(t: 2, h: 1, w: 1, multiplier: 2),
        .res(layers: 6), .down(t: 2, h: 2, w: 2, multiplier: 2), .res(layers: 2), .down(t: 2, h: 2, w: 2, multiplier: 2),
        .res(layers: 2),
    ]

    /// Blocks from the checkpoint's `vae.encoder_blocks`; nil for an unknown block type.
    public static func blocks(config: [String: Any]) -> [Block]? {
        guard let list = config["encoder_blocks"] as? [[Any]] else { return nil }
        var out: [Block] = []
        for entry in list {
            guard let name = entry.first as? String else { return nil }
            let params = entry.count > 1 ? entry[1] : nil
            let dict = params as? [String: Any] ?? [:]
            let layers = (params as? Int) ?? (dict["num_layers"] as? Int) ?? 1
            let multiplier = dict["multiplier"] as? Int ?? 2
            switch name {
            case "res_x": out.append(.res(layers: layers))
            case "compress_space_res": out.append(.down(t: 1, h: 2, w: 2, multiplier: multiplier))
            case "compress_time_res": out.append(.down(t: 2, h: 1, w: 1, multiplier: multiplier))
            case "compress_all_res": out.append(.down(t: 2, h: 2, w: 2, multiplier: multiplier))
            default: return nil
            }
        }
        return out
    }

    let weights: [String: MLXArray]
    let blocks: [Block]
    let meanOfMeans: MLXArray
    let stdOfMeans: MLXArray
    public let patchSize = 4
    public let latentChannels = 128

    /// `weights`: 2D kernels (O, kH, kW, I) and biases under the checkpoint names without `vae.encoder.`, in the
    /// compute type; statistics as in the checkpoint.
    init(weights: [String: MLXArray], blocks: [Block], meanOfMeans: MLXArray, stdOfMeans: MLXArray) {
        self.weights = weights
        self.blocks = blocks
        self.meanOfMeans = meanOfMeans
        self.stdOfMeans = stdOfMeans
    }

    /// All convolutions the blocks need (checked by `LTXWeights.loadImageEncoder`).
    static func convNames(_ blocks: [Block]) -> [String] {
        var names = ["conv_in", "conv_out"]
        for (i, block) in blocks.enumerated() {
            switch block {
            case .res(let layers):
                for j in 0 ..< layers { names += ["down_blocks.\(i).res_blocks.\(j).conv1", "down_blocks.\(i).res_blocks.\(j).conv2"] }
            case .down:
                names.append("down_blocks.\(i).conv")
            }
        }
        return names
    }

    func conv(_ x: MLXArray, _ name: String) -> MLXArray {
        conv2d(x, weights["\(name).conv.weight"]!, stride: 1, padding: 1) + weights["\(name).conv.bias"]!
    }

    static func pixelNorm(_ x: MLXArray) -> MLXArray {
        x * rsqrt(mean(x * x, axis: -1, keepDims: true) + 1e-8)
    }

    /// `rearrange("b c (d p1) (h p2) (w p3) -> b (c p1 p2 p3) d h w")` for one frame repeated `st` times, in NHWC.
    static func spaceToDepth(_ x: MLXArray, t st: Int, h sh: Int, w sw: Int) -> MLXArray {
        let b = x.dim(0), h = x.dim(1) / sh, w = x.dim(2) / sw, c = x.dim(3)
        var y = x.reshaped(b, h, sh, w, sw, c).transposed(0, 1, 3, 5, 2, 4)       // [b, h, w, c, sh, sw]
        if st > 1 {
            y = broadcast(expandedDimensions(y, axis: 4), to: [b, h, w, c, st, sh, sw])
        }
        return y.reshaped(b, h, w, c * st * sh * sw)
    }

    /// Patchify 4 × 4: `rearrange("b c (f p) (h q) (w r) -> b (c p r q) f h w")` with p = 1, in NHWC.
    func patchify(_ x: MLXArray) -> MLXArray {
        let b = x.dim(0), h = x.dim(1) / patchSize, w = x.dim(2) / patchSize, c = x.dim(3)
        return x.reshaped(b, h, patchSize, w, patchSize, c).transposed(0, 1, 3, 5, 4, 2)  // [b, h, w, c, r, q]
            .reshaped(b, h, w, c * patchSize * patchSize)
    }

    /// `image`: [1, H, W, 3] in [−1, 1] (H, W multiples of 32). Returns the normalized latent [1, 128, 1, H/32, W/32].
    public func encode(_ image: MLXArray) -> MLXArray {
        let dtype = weights["conv_in.conv.weight"]?.dtype ?? .float32
        var x = conv(patchify(image.asType(dtype)), "conv_in")
        for (i, block) in blocks.enumerated() {
            switch block {
            case .res(let layers):
                for j in 0 ..< layers {
                    let name = "down_blocks.\(i).res_blocks.\(j)"
                    var h = conv(silu(Self.pixelNorm(x)), "\(name).conv1")
                    h = conv(silu(Self.pixelNorm(h)), "\(name).conv2")
                    x = x + h
                }
            case .down(let st, let sh, let sw, let multiplier):
                let cin = x.dim(3)
                let cout = cin * multiplier
                // Residual: the input regrouped and averaged over groups of `group` channels.
                let group = cin * st * sh * sw / cout
                let skip = Self.spaceToDepth(x, t: st, h: sh, w: sw)
                let residual = skip.reshaped(skip.dim(0), skip.dim(1), skip.dim(2), cout, group).mean(axis: -1)
                let y = Self.spaceToDepth(conv(x, "down_blocks.\(i).conv"), t: st, h: sh, w: sw)
                x = y + residual
            }
            eval(x)
        }
        x = conv(silu(Self.pixelNorm(x)), "conv_out")
        // split instead of subscripts: subscripting crashed on arrays with more than three axes.
        let means = split(x, indices: [latentChannels], axis: 3)[0].asType(.float32)
        let normalized = (means - meanOfMeans) / stdOfMeans
        return expandedDimensions(normalized.transposed(0, 3, 1, 2), axis: 2)
    }
}
