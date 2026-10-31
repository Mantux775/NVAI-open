// TemporalUpscaler.swift - Latent temporal upsampler (LTX-2.5)
// Copyright 2026

import Foundation
@preconcurrency import MLX
import MLXNN

/// Doubles a latent's frame rate in latent space.
///
/// Same `LatentUpsampler` family as the spatial upscaler — identical residual
/// blocks, norm and entry/exit convolutions — differing only in the resampler:
/// a `Conv3d` widening to `2 * mid` followed by a pixel shuffle along **time**,
/// where the spatial one widens to `4 * mid` and shuffles in height and width.
///
/// One quirk of the temporal branch matters: the shuffle emits a leading frame
/// that must be dropped, because the first latent frame encodes a single pixel
/// frame rather than a group of eight. Keeping it would shift the whole clip by
/// one frame.
///
/// Like the spatial upscaler, this only carries motion across the new frame
/// grid — it does not invent detail. Upstream always follows it with a
/// refinement pass, which is what turns doubled frames into smoother motion
/// rather than a blurred interpolation.
class TemporalUpscaler: Module {
    @ModuleInfo(key: "initial_conv") var initialConv: Conv3d
    @ModuleInfo(key: "initial_norm") var initialNorm: UpscalerGroupNorm3D
    @ModuleInfo(key: "res_blocks") var resBlocks: [UpscalerResBlock3D]
    @ModuleInfo(key: "upsampler") var upsampler: TemporalRationalResampler
    @ModuleInfo(key: "post_upsample_res_blocks") var postResBlocks: [UpscalerResBlock3D]
    @ModuleInfo(key: "final_conv") var finalConv: Conv3d

    let inChannels: Int
    let midChannels: Int

    init(inChannels: Int = 128, midChannels: Int = 512, numBlocksPerStage: Int = 4) {
        self.inChannels = inChannels
        self.midChannels = midChannels

        self._initialConv.wrappedValue = Conv3d(
            inputChannels: inChannels, outputChannels: midChannels, kernelSize: 3, padding: 1)
        self._initialNorm.wrappedValue = UpscalerGroupNorm3D(
            numGroups: 32, numChannels: midChannels)
        self._resBlocks.wrappedValue = (0 ..< numBlocksPerStage).map { _ in
            UpscalerResBlock3D(channels: midChannels)
        }
        self._upsampler.wrappedValue = TemporalRationalResampler(midChannels: midChannels)
        self._postResBlocks.wrappedValue = (0 ..< numBlocksPerStage).map { _ in
            UpscalerResBlock3D(channels: midChannels)
        }
        self._finalConv.wrappedValue = Conv3d(
            inputChannels: midChannels, outputChannels: inChannels, kernelSize: 3, padding: 1)
        super.init()
    }

    /// `latent`: `[B, C, F, H, W]` → `[B, C, 2F - 1, H, W]`.
    func callAsFunction(_ latent: MLXArray) -> MLXArray {
        // Work channels-last, as the rest of the upscaler stack does.
        var x = latent.transposed(0, 2, 3, 4, 1)          // → [B, F, H, W, C]
        x = initialConv(x)
        x = initialNorm(x)
        x = MLXNN.silu(x)
        for block in resBlocks { x = block(x) }

        x = upsampler(x)
        // Drop the duplicate leading frame: latent frame 0 stands for a single
        // pixel frame, so the shuffle's first output has no source to belong to.
        x = x[0..., 1..., 0..., 0..., 0...]

        for block in postResBlocks { x = block(x) }
        x = finalConv(x)
        return x.transposed(0, 4, 1, 2, 3)                // → [B, C, F', H, W]
    }
}

/// `Conv3d` to `2 * mid` channels, then a pixel shuffle along time.
class TemporalRationalResampler: Module {
    @ModuleInfo(key: "conv") var conv: Conv3d
    let midChannels: Int

    init(midChannels: Int = 512) {
        self.midChannels = midChannels
        self._conv.wrappedValue = Conv3d(
            inputChannels: midChannels, outputChannels: 2 * midChannels,
            kernelSize: 3, padding: 1)
        super.init()
    }

    /// `x`: `[B, F, H, W, C]` → `[B, 2F, H, W, C]`.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let y = conv(x)                                   // [B, F, H, W, 2C]
        let (b, f, h, w) = (y.dim(0), y.dim(1), y.dim(2), y.dim(3))
        // Channels pack as (c, p_t) — the shuffle factor varies fastest, the
        // same convention the decoder's upsample uses.
        return y.reshaped([b, f, h, w, midChannels, 2])
            .transposed(0, 1, 5, 2, 3, 4)
            .reshaped([b, f * 2, h, w, midChannels])
    }
}

/// Load a temporal upscaler, converting PyTorch conv layouts to MLX.
func loadTemporalUpscaler(from weightsPath: String) throws -> TemporalUpscaler {
    LTXDebug.log("Loading temporal upscaler from \(weightsPath)...")
    let raw = try MLX.loadArrays(url: URL(fileURLWithPath: weightsPath))

    let midChannels = raw["res_blocks.0.conv1.weight"]?.dim(0) ?? 512
    let upscaler = TemporalUpscaler(inChannels: 128, midChannels: midChannels)

    var updates: [String: MLXArray] = [:]
    for (key, value) in raw {
        var newKey = key
        // Python wraps the resampler in nn.Sequential (index 0); Swift names it.
        if newKey.hasPrefix("upsampler.0.") {
            newKey = newKey.replacingOccurrences(of: "upsampler.0.", with: "upsampler.conv.")
        }
        var newValue = value
        // Conv3d: PyTorch (O, I, D, H, W) → MLX (O, D, H, W, I)
        if newKey.contains("conv") && newKey.hasSuffix(".weight") && value.ndim == 5 {
            newValue = value.transposed(0, 2, 3, 4, 1)
        }
        updates[newKey] = newValue
    }

    let declared = Dictionary(uniqueKeysWithValues: upscaler.parameters().flattened())
    let missing = declared.keys.filter { updates[$0] == nil }.sorted()
    guard missing.isEmpty else {
        throw LTXError.weightLoadingFailed(
            "Temporal upscaler missing \(missing.count) parameters, e.g. "
            + missing.prefix(4).joined(separator: ", "))
    }
    _ = upscaler.update(parameters: ModuleParameters.unflattened(updates))
    eval(upscaler.parameters())

    // Values, not names: a key can match and still update nothing.
    let after = Dictionary(uniqueKeysWithValues: upscaler.parameters().flattened())
    for (key, value) in updates where declared[key] != nil {
        guard let live = after[key],
              MLX.allClose(live.asType(.float32), value.asType(.float32), atol: 1e-6).item(Bool.self)
        else {
            throw LTXError.weightLoadingFailed("Temporal upscaler parameter \(key) did not load")
        }
    }
    LTXDebug.log("Temporal upscaler ready (mid \(midChannels))")
    return upscaler
}
