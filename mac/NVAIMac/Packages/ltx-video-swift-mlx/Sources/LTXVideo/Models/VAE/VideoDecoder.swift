// VideoDecoder.swift - Video VAE Decoder for LTX-2.3
// Matches Python SimpleVideoDecoder architecture exactly
// Copyright 2025

import Foundation
@preconcurrency import MLX
import MLXNN
import MLXRandom

// MARK: - Pixel Norm (Channel-wise)

/// Pixel normalization across channels (parameter-free)
func vaePixelNorm(_ x: MLXArray, eps: Float = 1e-8) -> MLXArray {
    let meanSquared = MLX.mean(x * x, axis: 1, keepDims: true)
    return x / MLX.sqrt(meanSquared + eps)
}

// MARK: - VAE ResBlock 3D (LTX-2.3 — no timestep conditioning)

/// 3D residual block with pixel norm
/// LTX-2.3: PixelNorm -> SiLU -> Conv (no scale/shift table)
class VAEResBlock3d: Module {
    let channels: Int
    @ModuleInfo(key: "conv1") var conv1: CausalConv3dFull
    @ModuleInfo(key: "conv2") var conv2: CausalConv3dFull

    init(channels: Int) {
        self.channels = channels
        self._conv1.wrappedValue = CausalConv3dFull(
            inChannels: channels, outChannels: channels, kernelSize: 3, spatialPaddingMode: .zeros
        )
        self._conv2.wrappedValue = CausalConv3dFull(
            inChannels: channels, outChannels: channels, kernelSize: 3, spatialPaddingMode: .zeros
        )
    }

    func callAsFunction(_ x: MLXArray, causal: Bool = false) -> MLXArray {
        let residual = x

        var h = vaePixelNorm(x)
        h = MLXNN.silu(h)
        h = conv1(h, causal: causal)

        h = vaePixelNorm(h)
        h = MLXNN.silu(h)
        h = conv2(h, causal: causal)

        return h + residual
    }
}

// MARK: - VAE ResBlock Group

/// Group of residual blocks (LTX-2.3: no timestep conditioning)
class VAEResBlockGroup: Module {
    let channels: Int
    @ModuleInfo(key: "res_blocks") var resBlocks: [VAEResBlock3d]

    init(channels: Int, numBlocks: Int) {
        self.channels = channels
        self._resBlocks.wrappedValue = (0..<numBlocks).map { _ in
            VAEResBlock3d(channels: channels)
        }
    }

    func callAsFunction(_ x: MLXArray, causal: Bool = false) -> MLXArray {
        var h = x
        for block in resBlocks {
            h = block(h, causal: causal)
        }
        return h
    }
}

// MARK: - VAE Depth-to-Space Upsample 3D

/// Upsample using depth-to-space (pixel shuffle) in 3D with residual connection
///
/// Supports variable factors: (2,2,2), (2,1,1), (1,2,2) etc.
/// Frame trimming: removes first frame after D2S when temporal factor > 1
class VAEDepthToSpaceUpsample3d: Module {
    let factor: (Int, Int, Int)
    let factorProduct: Int
    let outChannels: Int
    let useResidual: Bool

    @ModuleInfo(key: "conv") var conv: CausalConv3dFull

    init(inChannels: Int, outChannels: Int, factor: (Int, Int, Int), residual: Bool = false) {
        self.factor = factor
        self.useResidual = residual
        let (ft, fh, fw) = factor
        self.factorProduct = ft * fh * fw
        self.outChannels = outChannels

        let convOutChannels = outChannels * factorProduct
        self._conv.wrappedValue = CausalConv3dFull(
            inChannels: inChannels, outChannels: convOutChannels, kernelSize: 3, spatialPaddingMode: .zeros
        )
    }

    private func depthToSpace(_ x: MLXArray, cOut: Int) -> MLXArray {
        let b = x.dim(0)
        let t = x.dim(2)
        let h = x.dim(3)
        let w = x.dim(4)
        let (ft, fh, fw) = factor

        var out = x.reshaped([b, cOut, ft, fh, fw, t, h, w])
        out = out.transposed(0, 1, 5, 2, 6, 3, 7, 4)
        out = out.reshaped([b, cOut, t * ft, h * fh, w * fw])
        return out
    }

    func callAsFunction(_ x: MLXArray, causal: Bool = false) -> MLXArray {
        let (ft, _, _) = factor

        // Residual path: D2S on raw input, then tile channels if needed
        var residualVal: MLXArray? = nil
        if useResidual {
            let cIn = x.dim(1)
            let cD2s = cIn / factorProduct
            var res = depthToSpace(x, cOut: cD2s)
            // Trim first frame when temporal factor > 1
            if ft > 1 {
                res = res[0..., 0..., 1..., 0..., 0...]
            }
            // Tile channels to match outChannels
            let channelRepeats = outChannels / cD2s
            if channelRepeats > 1 {
                var parts = [MLXArray]()
                for _ in 0..<channelRepeats {
                    parts.append(res)
                }
                res = MLX.concatenated(parts, axis: 1)
            }
            residualVal = res
        }

        // Main path: conv then D2S
        var h = conv(x, causal: causal)
        h = depthToSpace(h, cOut: outChannels)

        // Trim first frame
        if ft > 1 {
            h = h[0..., 0..., 1..., 0..., 0...]
        }

        // Add residual (only used by encoder's SpaceToDepthDownsample, not decoder)
        if let res = residualVal {
            h = h + res
        }

        return h
    }
}

// MARK: - Unpatchify

/// Unpatchify operation: expand spatial patches
func unpatchify(
    _ x: MLXArray,
    patchSizeHW: Int = 4,
    patchSizeT: Int = 1
) -> MLXArray {
    let b = x.dim(0)
    let cPatched = x.dim(1)
    let t = x.dim(2)
    let h = x.dim(3)
    let w = x.dim(4)

    let c = cPatched / (patchSizeHW * patchSizeHW * patchSizeT)

    var out = x.reshaped([b, c, patchSizeT, patchSizeHW, patchSizeHW, t, h, w])
    // Lightricks convention: pW before pH (matching encoder patchify and conv_out weights)
    out = out.transposed(0, 1, 5, 2, 6, 4, 7, 3)
    out = out.reshaped([b, c, t * patchSizeT, h * patchSizeHW, w * patchSizeHW])

    return out
}

// MARK: - Video Decoder

/// Video VAE Decoder for LTX-2.3 matching Python SimpleVideoDecoder
///
/// Architecture (LTX-2.3 — no timestep conditioning):
/// - conv_in: 128 -> 1024
/// - up_blocks_0: 2 res blocks (1024 ch)
/// - up_blocks_1: D2S upsample (1024 -> 512, factor 2,2,2)
/// - up_blocks_2: 2 res blocks (512 ch)
/// - up_blocks_3: D2S upsample (512 -> 512, factor 2,2,2)
/// - up_blocks_4: 4 res blocks (512 ch)
/// - up_blocks_5: D2S upsample (512 -> 256, factor 2,1,1)
/// - up_blocks_6: 6 res blocks (256 ch)
/// - up_blocks_7: D2S upsample (256 -> 128, factor 1,2,2)
/// - up_blocks_8: 4 res blocks (128 ch)
/// - PixelNorm + SiLU
/// - conv_out: 128 -> 48
/// - unpatchify: 48 -> 3 channels, 4x4 spatial
///
/// Frame formula: output_frames = 8 * (latent_frames - 1) + 1
class VideoDecoder: Module {
    let patchSize: Int
    let causal: Bool

    @ParameterInfo(key: "mean_of_means") var meanOfMeans: MLXArray
    @ParameterInfo(key: "std_of_means") var stdOfMeans: MLXArray

    @ModuleInfo(key: "conv_in") var convIn: CausalConv3dFull
    @ModuleInfo(key: "conv_out") var convOut: CausalConv3dFull

    @ModuleInfo(key: "up_blocks_0") var upBlocks0: VAEResBlockGroup
    @ModuleInfo(key: "up_blocks_1") var upBlocks1: VAEDepthToSpaceUpsample3d
    @ModuleInfo(key: "up_blocks_2") var upBlocks2: VAEResBlockGroup
    @ModuleInfo(key: "up_blocks_3") var upBlocks3: VAEDepthToSpaceUpsample3d
    @ModuleInfo(key: "up_blocks_4") var upBlocks4: VAEResBlockGroup
    @ModuleInfo(key: "up_blocks_5") var upBlocks5: VAEDepthToSpaceUpsample3d
    @ModuleInfo(key: "up_blocks_6") var upBlocks6: VAEResBlockGroup
    @ModuleInfo(key: "up_blocks_7") var upBlocks7: VAEDepthToSpaceUpsample3d
    @ModuleInfo(key: "up_blocks_8") var upBlocks8: VAEResBlockGroup

    init(patchSize: Int = 4, causal: Bool = false) {
        self.patchSize = patchSize
        self.causal = causal

        self._meanOfMeans.wrappedValue = MLXArray.zeros([128])
        self._stdOfMeans.wrappedValue = MLXArray.ones([128])

        let actualOutChannels = 3 * patchSize * patchSize  // 48

        self._convIn.wrappedValue = CausalConv3dFull(
            inChannels: 128, outChannels: 1024, kernelSize: 3, spatialPaddingMode: .zeros
        )
        self._convOut.wrappedValue = CausalConv3dFull(
            inChannels: 128, outChannels: actualOutChannels, kernelSize: 3, spatialPaddingMode: .zeros
        )

        // 5 resblock groups: channels [1024, 512, 512, 256, 128], blocks [2, 2, 4, 6, 4]
        // D2S blocks: decoder uses compress_all/compress_space/compress_time (NO residual)
        // NOT compress_all_res (only encoder uses _res variants)
        self._upBlocks0.wrappedValue = VAEResBlockGroup(channels: 1024, numBlocks: 2)
        self._upBlocks1.wrappedValue = VAEDepthToSpaceUpsample3d(
            inChannels: 1024, outChannels: 512, factor: (2, 2, 2), residual: false
        )
        self._upBlocks2.wrappedValue = VAEResBlockGroup(channels: 512, numBlocks: 2)
        self._upBlocks3.wrappedValue = VAEDepthToSpaceUpsample3d(
            inChannels: 512, outChannels: 512, factor: (2, 2, 2), residual: false
        )
        self._upBlocks4.wrappedValue = VAEResBlockGroup(channels: 512, numBlocks: 4)
        self._upBlocks5.wrappedValue = VAEDepthToSpaceUpsample3d(
            inChannels: 512, outChannels: 256, factor: (2, 1, 1), residual: false
        )
        self._upBlocks6.wrappedValue = VAEResBlockGroup(channels: 256, numBlocks: 6)
        self._upBlocks7.wrappedValue = VAEDepthToSpaceUpsample3d(
            inChannels: 256, outChannels: 128, factor: (1, 2, 2), residual: false
        )
        self._upBlocks8.wrappedValue = VAEResBlockGroup(channels: 128, numBlocks: 4)
    }

    /// Save debug tensor dump if debug mode is enabled
    private func dumpTensor(_ x: MLXArray, name: String) {
        guard LTXDebug.isEnabled else { return }
        let dumpDir = "/tmp/debug_dumps/swift"
        try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
        let toSave = x.asType(.float32)
        MLX.eval(toSave)
        try? MLX.save(arrays: ["data": toSave], url: URL(fileURLWithPath: "\(dumpDir)/vae_\(name).safetensors"))
        LTXDebug.log("Dumped vae_\(name): \(toSave.shape)")
    }

    func callAsFunction(_ sample: MLXArray) -> MLXArray {
        LTXDebug.log("VAE Decoder input: \(sample.shape)")

        var x = sample

        // Denormalize latent using per-channel statistics
        let meanExp = meanOfMeans.asType(.float32).reshaped([1, -1, 1, 1, 1])
        let stdExp = stdOfMeans.asType(.float32).reshaped([1, -1, 1, 1, 1])
        x = (x.asType(.float32) * stdExp + meanExp).asType(x.dtype)
        LTXDebug.log("After denormalize: mean=\(x.mean().item(Float.self))")
        dumpTensor(x, name: "after_denorm")

        // Conv in
        x = convIn(x, causal: causal)
        LTXDebug.log("After conv_in: \(x.shape)")

        // Up blocks — first half (high-channel ops, eval mid-point to bound memory)
        x = upBlocks0(x, causal: causal)
        x = upBlocks1(x, causal: causal)
        x = upBlocks2(x, causal: causal)
        x = upBlocks3(x, causal: causal)
        x = upBlocks4(x, causal: causal)
        eval(x)  // Single mid-point eval to bound compute graph
        Memory.clearCache()

        // Up blocks — second half (lower channels, spatial upsampling)
        x = upBlocks5(x, causal: causal)
        x = upBlocks6(x, causal: causal)
        x = upBlocks7(x, causal: causal)
        x = upBlocks8(x, causal: causal)

        // Final norm + activation
        x = vaePixelNorm(x)
        x = MLXNN.silu(x)

        // Conv out
        x = convOut(x, causal: causal)

        // Unpatchify: (B, 48, T, H, W) -> (B, 3, T, H*4, W*4)
        x = unpatchify(x, patchSizeHW: patchSize, patchSizeT: 1)
        eval(x)  // Single final eval
        LTXDebug.log("After unpatchify: \(x.shape)")

        return x
    }
}

// MARK: - Decode Video

/// Decode a video latent with the *diffusion* decoder.
///
/// Same contract as the convolutional overload — `[F, H, W, C]` in `[0, 1]` —
/// and the same temporal tiling, which matters more here: the diffusion stage
/// runs attention over the full-resolution volume, so peak memory grows with
/// the clip length far faster than the conv decoder's does.
func decodeVideo(
    latent: MLXArray,
    decoder: DiffusionVideoDecoder,
    temporalTileSize: Int = 0,
    temporalTileOverlap: Int = 1
) -> MLXArray {
    var input = latent
    if input.ndim == 4 {
        input = MLX.expandedDimensions(input, axis: 0)
    }
    let latentFrames = input.dim(2)

    if temporalTileSize > 0 && latentFrames > temporalTileSize {
        LTXDebug.log("DiffVAE temporal tiling: \(latentFrames) latent frames, tile=\(temporalTileSize)")
        var chunks: [MLXArray] = []
        var start = 0
        while start < latentFrames {
            let end = min(start + temporalTileSize, latentFrames)
            let chunk = input[0..., 0..., start ..< end, 0..., 0...]
            chunks.append(decoder.decode(latent: chunk))
            start = end
        }
        return MLX.concatenated(chunks, axis: 0)
    }
    return decoder.decode(latent: input)
}

/// Decode a video latent tensor with the given decoder
///
/// For short videos (latent frames <= `temporalTileSize`), decodes in a single pass.
/// For longer videos, uses temporal tiling with overlap blending to reduce peak memory.
///
/// - Parameters:
///   - latent: Latent tensor (B, C, F, H, W) or (C, F, H, W)
///   - decoder: The VAE decoder
///   - temporalTileSize: Max latent frames per chunk (0 = disabled). Default 8.
///   - temporalTileOverlap: Latent frames of overlap between chunks. Default 1.
/// - Returns: Decoded frames (F, H, W, C) in [0, 1]
func decodeVideo(
    latent: MLXArray,
    decoder: VideoDecoder,
    timestep: Float? = nil,
    temporalTileSize: Int = 0,
    temporalTileOverlap: Int = 1
) -> MLXArray {
    var input = latent

    // Add batch dimension if needed
    if input.ndim == 4 {
        input = MLX.expandedDimensions(input, axis: 0)
    }

    let latentFrames = input.dim(2)

    // Use temporal tiling for long videos
    if temporalTileSize > 0 && latentFrames > temporalTileSize {
        LTXDebug.log("VAE temporal tiling: \(latentFrames) latent frames, tile=\(temporalTileSize), overlap=\(temporalTileOverlap)")
        let decoded = decodeWithTemporalTiling(
            input,
            decoder: decoder,
            tileSize: temporalTileSize,
            overlap: temporalTileOverlap
        )
        return decoded
    }

    // Single-pass decode for short videos
    let decoded = decoder(input)

    LTXDebug.log("VAE raw output: mean=\(decoded.mean().item(Float.self)), min=\(decoded.min().item(Float.self)), max=\(decoded.max().item(Float.self))")

    // Normalize to [0, 1] range
    var frames = MLX.clip((decoded + 1.0) / 2.0, min: 0.0, max: 1.0)

    // Rearrange from (B, C, F, H, W) to (F, H, W, C)
    frames = frames[0]  // Remove batch dim
    frames = frames.transposed(1, 2, 3, 0)  // (C, F, H, W) -> (F, H, W, C)

    return frames
}

/// Decode latent with temporal tiling for long videos
///
/// Splits the latent along the temporal axis into overlapping chunks,
/// decodes each independently, and blends the overlap regions with
/// linear interpolation for smooth transitions.
///
/// Frame formula per chunk: output_frames = 8 * (latent_frames - 1) + 1
private func decodeWithTemporalTiling(
    _ input: MLXArray,
    decoder: VideoDecoder,
    tileSize: Int,
    overlap: Int
) -> MLXArray {
    let totalLatentFrames = input.dim(2)
    let stride = tileSize - overlap

    // Pixel overlap = 8 * overlap (each latent frame expands to ~8 pixels)
    let pixelOverlap = 8 * overlap

    var decodedChunks: [MLXArray] = []  // Each is (B, C, F_chunk, H, W)
    var chunkIdx = 0

    var start = 0
    while start < totalLatentFrames {
        let end = min(start + tileSize, totalLatentFrames)
        let chunk = input[0..., 0..., start..<end, 0..., 0...]
        LTXDebug.log("  VAE tile \(chunkIdx): latent frames \(start)..<\(end) (\(end - start) frames)")

        let decoded = decoder(chunk)
        eval(decoded)  // eval per tile (needed to bound memory)

        decodedChunks.append(decoded)
        chunkIdx += 1

        if end >= totalLatentFrames { break }
        start += stride
    }
    Memory.clearCache()  // Single clear after all tiles decoded

    if decodedChunks.count == 1 {
        // Single chunk — no blending needed
        let decoded = decodedChunks[0]
        var frames = MLX.clip((decoded + 1.0) / 2.0, min: 0.0, max: 1.0)
        frames = frames[0]
        frames = frames.transposed(1, 2, 3, 0)
        return frames
    }

    // Pre-compute blend weights once (vectorized, not CPU loop)
    let blendWeights: MLXArray?
    if pixelOverlap > 0 {
        blendWeights = MLX.linspace(Float(0), Float(1), count: pixelOverlap)
            .reshaped([1, 1, pixelOverlap, 1, 1])
    } else {
        blendWeights = nil
    }

    // Blend overlapping regions with linear interpolation
    LTXDebug.log("Blending \(decodedChunks.count) temporal tiles (pixel overlap=\(pixelOverlap))")
    var result = decodedChunks[0]

    for i in 1..<decodedChunks.count {
        let next = decodedChunks[i]
        let resultFrames = result.dim(2)
        let nextFrames = next.dim(2)

        if let weights = blendWeights, pixelOverlap < resultFrames && pixelOverlap < nextFrames {
            // Extract overlap regions
            let resultOverlap = result[0..., 0..., (resultFrames - pixelOverlap)..., 0..., 0...]
            let nextOverlap = next[0..., 0..., 0..<pixelOverlap, 0..., 0...]

            // Blend: linear interpolation
            let blended = resultOverlap * (1 - weights) + nextOverlap * weights

            // Concatenate: result[:-overlap] + blended + next[overlap:]
            let resultPart = result[0..., 0..., 0..<(resultFrames - pixelOverlap), 0..., 0...]
            let nextPart = next[0..., 0..., pixelOverlap..., 0..., 0...]
            result = MLX.concatenated([resultPart, blended, nextPart], axis: 2)
        } else {
            // No overlap — just concatenate
            result = MLX.concatenated([result, next], axis: 2)
        }
    }
    eval(result)  // Single eval after all blending

    LTXDebug.log("VAE tiled output: \(result.shape)")

    // Normalize to [0, 1] and rearrange
    var frames = MLX.clip((result + 1.0) / 2.0, min: 0.0, max: 1.0)
    frames = frames[0]  // Remove batch dim
    frames = frames.transposed(1, 2, 3, 0)  // (C, F, H, W) -> (F, H, W, C)

    return frames
}
