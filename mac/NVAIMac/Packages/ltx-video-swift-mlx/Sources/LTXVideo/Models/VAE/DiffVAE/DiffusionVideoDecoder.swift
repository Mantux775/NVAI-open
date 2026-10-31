// DiffusionVideoDecoder.swift - LTX-2.5's diffusion video VAE decoder
// Copyright 2026

import Foundation
@preconcurrency import MLX
import MLXNN

/// Architecture of the diffusion decoder, read from the checkpoint's own
/// safetensors metadata rather than hardcoded — the shipped 2.5 decoder is
/// twice as wide as the reference code's default constants, so guessing from
/// the source would have built the wrong model.
public struct DiffVAEConfig: Sendable, Equatable {
    public var stageChannels: [Int]        // e.g. [2048, 1024, 512, 512, 256]
    public var stageDepths: [Int]          // e.g. [4, 6, 4, 2, 8]
    public var stageKernels: [[Int]]       // per stage (K_t, K_h, K_w)
    public var headDim: Int
    public var patchSize: Int
    public var outChannels: Int
    public var latentChannels: Int
    public var timestepScaleMultiplier: Float
    public var numInferenceSteps: Int
    public var predictsX0: Bool

    /// Upsample strides and channel-reduction factors, in stage order. Fixed by
    /// the decoder layout (spatial ×2, then temporal ×2, then two full ×2),
    /// composing to the VAE's 32× spatial / 8× temporal compression.
    public static let upsampleStrides: [(stride: (Int, Int, Int), reduction: Int)] = [
        ((1, 2, 2), 2), ((2, 1, 1), 2), ((2, 2, 2), 1), ((2, 2, 2), 2),
    ]

    /// Parse from the `config` entry of the file's safetensors metadata.
    public static func fromCheckpointMetadata(_ metadata: [String: String]) throws -> DiffVAEConfig {
        guard let raw = metadata["config"], let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vae = root["vae"] as? [String: Any],
              let decoder = vae["decoder"] as? [String: Any]
        else {
            throw LTXError.weightLoadingFailed(
                "This VAE file carries no decoder config in its metadata — it is probably "
                + "the convolutional VAE, which has its own loader.")
        }
        guard let channels = decoder["stage_channels"] as? [Int],
              let depths = decoder["stage_depths"] as? [Int],
              let kernels = decoder["stage_kernels"] as? [[Int]]
        else {
            throw LTXError.weightLoadingFailed("Decoder config lacks stage_channels/depths/kernels")
        }
        let encoder = vae["encoder"] as? [String: Any]
        return DiffVAEConfig(
            stageChannels: channels,
            stageDepths: depths,
            stageKernels: kernels,
            headDim: decoder["head_dim"] as? Int ?? 64,
            patchSize: decoder["patch_size"] as? Int ?? 4,
            outChannels: decoder["out_channels"] as? Int ?? 3,
            latentChannels: encoder?["out_channels"] as? Int ?? 128,
            timestepScaleMultiplier: (decoder["timestep_scale_multiplier"] as? NSNumber)?.floatValue ?? 1000.0,
            numInferenceSteps: decoder["default_num_inference_steps"] as? Int ?? 1,
            predictsX0: (vae["model_output_type"] as? String ?? "x0") == "x0")
    }
}

/// LTX-2.5's diffusion video decoder.
///
/// Four deterministic stages upsample the latent into a full-resolution
/// *context* volume; a fifth stage of diffusion blocks then denoises patchified
/// pixels conditioned on that context. The shipped 2.5 checkpoint declares one
/// inference step predicting x₀ directly, so the "diffusion" is a single guided
/// forward pass — no sampling loop, and a cost close to the convolutional
/// decoder's rather than a multiple of it.
///
/// Layout is channels-last `[B, T, H, W, C]` throughout, matching the reference;
/// only the entry and exit convert to and from the `[B, C, F, H, W]` the rest of
/// this package uses.
public class DiffusionVideoDecoder: Module {
    public let config: DiffVAEConfig

    @ModuleInfo(key: "conv_in") var convIn: Linear
    @ModuleInfo(key: "conv_in_x_t") var convInXT: Linear
    @ModuleInfo(key: "conv_out") var convOut: Linear
    @ModuleInfo(key: "norm_out") var normOut: RMSNorm
    @ModuleInfo(key: "det_stages") var detStages: [[DiffVAENABlock]]
    @ModuleInfo(key: "upsamples") var upsamples: [DiffVAEUpsample]
    @ModuleInfo(key: "diff_blocks") var diffBlocks: [DiffVAEDiffusionBlock]
    @ModuleInfo(key: "t_embedder") var tEmbedder: DiffVAETimestepEmbedder
    @ModuleInfo(key: "shared_adaln") var sharedAdaLN: DiffVAESharedAdaLN
    @ParameterInfo(key: "type_emb") var typeEmb: MLXArray

    /// Per-channel latent statistics, as on the convolutional decoder.
    ///
    /// Named without dots on purpose: `ModuleParameters.unflattened` splits keys
    /// on ".", so a parameter called `per_channel_statistics.mean-of-means`
    /// silently never receives its value. The loader maps the checkpoint's
    /// dotted names onto these.
    @ParameterInfo(key: "mean_of_means") var meanOfMeans: MLXArray
    @ParameterInfo(key: "std_of_means") var stdOfMeans: MLXArray

    public init(config: DiffVAEConfig) {
        self.config = config
        let patched = config.outChannels * config.patchSize * config.patchSize

        self._convIn.wrappedValue = Linear(config.latentChannels, config.stageChannels[0], bias: true)
        self._convInXT.wrappedValue = Linear(patched, config.stageChannels[4], bias: true)
        self._convOut.wrappedValue = Linear(config.stageChannels[4], patched, bias: true)
        self._normOut.wrappedValue = RMSNorm(dims: config.stageChannels[4], eps: 1e-6)

        self._detStages.wrappedValue = (0 ..< 4).map { stage in
            (0 ..< config.stageDepths[stage]).map { _ in
                DiffVAENABlock(
                    dim: config.stageChannels[stage],
                    kernel: (config.stageKernels[stage][0],
                             config.stageKernels[stage][1],
                             config.stageKernels[stage][2]),
                    headDim: config.headDim)
            }
        }
        self._upsamples.wrappedValue = (0 ..< 4).map { i in
            DiffVAEUpsample(
                inChannels: config.stageChannels[i],
                stride: DiffVAEConfig.upsampleStrides[i].stride,
                reductionFactor: DiffVAEConfig.upsampleStrides[i].reduction)
        }
        let diffDim = config.stageChannels[4]
        self._diffBlocks.wrappedValue = (0 ..< config.stageDepths[4]).map { _ in
            DiffVAEDiffusionBlock(
                dim: diffDim,
                kernel: (config.stageKernels[4][0], config.stageKernels[4][1], config.stageKernels[4][2]),
                contextChannels: diffDim,
                headDim: config.headDim)
        }
        self._tEmbedder.wrappedValue = DiffVAETimestepEmbedder(hiddenDim: 384)
        self._sharedAdaLN.wrappedValue = DiffVAESharedAdaLN(dim: diffDim, embeddingDim: 384)
        self._typeEmb.wrappedValue = MLXArray.zeros([config.latentChannels])
        self._meanOfMeans.wrappedValue = MLXArray.zeros([config.latentChannels])
        self._stdOfMeans.wrappedValue = MLXArray.ones([config.latentChannels])
        super.init()
    }

    // MARK: - Patch helpers

    /// `[B, C, F, H, W]` → `[B, C·p², F, H/p, W/p]` (space to depth).
    static func patchify(_ x: MLXArray, patch: Int) -> MLXArray {
        guard patch > 1 else { return x }
        let (B, C, F, H, W) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3), x.dim(4))
        return x.reshaped([B, C, F, H / patch, patch, W / patch, patch])
            // b c f h q w r -> b (c r q) f h w
            .transposed(0, 1, 6, 4, 2, 3, 5)
            .reshaped([B, C * patch * patch, F, H / patch, W / patch])
    }

    /// Mirror-pad one axis up to `target`, the edge policy the reference uses
    /// for spatial padding (repeated content would fold energy into the border
    /// windows; mirroring keeps the local statistics).
    static func mirrorPad(_ x: MLXArray, axis: Int, to target: Int) -> MLXArray {
        var out = x
        while out.dim(axis) < target {
            let n = out.dim(axis)
            let take = min(n, target - n)
            // reflect the last `take` rows, excluding the edge row itself when possible
            var slices: [MLXArray] = [out]
            for i in 0 ..< take {
                let index = max(0, n - 2 - i)
                slices.append(out.take(MLXArray([Int32(index)]), axis: axis))
            }
            out = MLX.concatenated(slices, axis: axis)
        }
        return out
    }

    /// Inverse of ``patchify``.
    static func unpatchify(_ x: MLXArray, patch: Int) -> MLXArray {
        guard patch > 1 else { return x }
        let (B, CP, F, H, W) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3), x.dim(4))
        let C = CP / (patch * patch)
        return x.reshaped([B, C, patch, patch, F, H, W])
            // b (c r q) f h w -> b c f (h q) (w r)
            .transposed(0, 1, 4, 5, 3, 6, 2)
            .reshaped([B, C, F, H * patch, W * patch])
    }

    // MARK: - Minimum geometry

    /// Smallest latent that keeps every stage at least as large as its own
    /// attention kernel.
    ///
    /// The reference refuses a volume smaller than the kernel outright and pads
    /// the latent to reach it; this port used to shrink the kernel instead,
    /// which is a different operation from the trained one. Derived from the
    /// config rather than hardcoded, since the kernels and the upsample chain
    /// both come from the checkpoint.
    var minimumLatentShape: (frames: Int, height: Int, width: Int) {
        var minT = 1, minH = 1, minW = 1
        // Walk the stages forward, expressing each stage's requirement back in
        // latent units through the upsamples that precede it.
        var scaleT = 1, scaleH = 1, scaleW = 1        // volume = scale * latent (temporal: minus drop)
        var dropT = 0                                  // frames lost to leading-frame drops
        for stage in 0 ..< config.stageKernels.count {
            let k = config.stageKernels[stage]
            // stage volume T = scaleT * latentT - dropT  ≥  k[0]
            minT = max(minT, Int(ceil((Double(k[0]) + Double(dropT)) / Double(scaleT))))
            minH = max(minH, Int(ceil(Double(k[1]) / Double(scaleH))))
            minW = max(minW, Int(ceil(Double(k[2]) / Double(scaleW))))
            guard stage < DiffVAEConfig.upsampleStrides.count else { break }
            let up = DiffVAEConfig.upsampleStrides[stage].stride
            scaleT *= up.0; scaleH *= up.1; scaleW *= up.2
            if up.0 == 2 { dropT = dropT * 2 + 1 }
        }
        return (minT, minH, minW)
    }

    // MARK: - Forward

    /// Deterministic stages: latent → context volume, channels-last.
    func context(from latent: MLXArray) -> MLXArray {
        // Un-normalise with the per-channel statistics, as the conv decoder does.
        let mean = meanOfMeans.reshaped([1, -1, 1, 1, 1]).asType(latent.dtype)
        let std = stdOfMeans.reshaped([1, -1, 1, 1, 1]).asType(latent.dtype)
        let z = latent * std + mean

        var x = convIn(z.transposed(0, 2, 3, 4, 1))   // → [B, F, H, W, C]
        for stage in 0 ..< 4 {
            for block in detStages[stage] {
                x = block(x)
                MLX.eval(x)   // bound the command buffer; see NeighborhoodAttention3D
            }
            x = upsamples[stage](x, dropLeadingFrame: true)
            MLX.eval(x)
        }
        return x
    }

    /// One diffusion step: predict pixels from the context and the current
    /// noised pixels. Returns `[B, C, F, H, W]` in `[-1, 1]`.
    func diffusionStep(context ctx: MLXArray, xT: MLXArray, t: MLXArray) -> MLXArray {
        let patched = Self.patchify(xT, patch: config.patchSize)
        let xHalf = convInXT(patched.transposed(0, 2, 3, 4, 1))
        var contextAndX = MLX.concatenated([ctx, xHalf], axis: -1)

        let tEmb = tEmbedder(config.timestepScaleMultiplier * t, dtype: xHalf.dtype)
        let modulation = sharedAdaLN(tEmb)

        var x = xHalf
        for block in diffBlocks {
            x = block(contextAndX, modulation: modulation)
            MLX.eval(x)
            contextAndX = MLX.concatenated([ctx, x], axis: -1)
        }
        x = convOut(normOut(x))
        return Self.unpatchify(x.transposed(0, 4, 1, 2, 3), patch: config.patchSize)
    }

    /// Decode a latent to pixels in `[0, 1]`, shaped `[F, H, W, C]` like the
    /// convolutional decoder's output, so callers are interchangeable.
    ///
    /// The shipped checkpoint is single-step x₀: the model's prediction *is*
    /// the image, and the initial `x_t` is pure noise at t = 1.
    public func decode(latent: MLXArray, seed: UInt64? = nil) -> MLXArray {
        // Pad up to the kernel floor rather than shrinking kernels: the extra
        // rows are cropped from the pixels at the end, so a short clip decodes
        // through exactly the trained operation.
        let trueFrames = latent.dim(2), trueHeight = latent.dim(3), trueWidth = latent.dim(4)
        let minimum = minimumLatentShape
        var padded = latent
        if trueFrames < minimum.frames {
            let last = padded[0..., 0..., (trueFrames - 1) ..< trueFrames, 0..., 0...]
            let repeats = (0 ..< (minimum.frames - trueFrames)).map { _ in last }
            padded = MLX.concatenated([padded] + repeats, axis: 2)   // repeat the last frame
        }
        if trueHeight < minimum.height {
            padded = Self.mirrorPad(padded, axis: 3, to: minimum.height)
        }
        if trueWidth < minimum.width {
            padded = Self.mirrorPad(padded, axis: 4, to: minimum.width)
        }
        if padded.shape != latent.shape {
            LTXDebug.log("[DiffVAE] padded latent \(latent.shape) → \(padded.shape) for the kernel floor")
        }

        let ctx = context(from: padded)
        let (B, F, H, W) = (ctx.dim(0), ctx.dim(1), ctx.dim(2), ctx.dim(3))
        let pixelShape = [B, config.outChannels, F, H * config.patchSize, W * config.patchSize]

        if let seed { MLXRandom.seed(seed) }
        var xT = MLXRandom.normal(pixelShape).asType(ctx.dtype)

        let steps = max(1, config.numInferenceSteps)
        // t goes 1 → 1/steps, matching the reference's linspace.
        let timesteps = (0 ..< steps).map { 1.0 - Float($0) * (1.0 - 1.0 / Float(steps)) / Float(max(1, steps - 1)) }

        for (i, t) in timesteps.enumerated() {
            let tArray = MLXArray([t]).asType(.float32)
            let prediction = diffusionStep(context: ctx, xT: xT, t: tArray)
            if config.predictsX0 && i == steps - 1 {
                xT = prediction
            } else {
                // Euler on the velocity implied by an x₀ prediction.
                let tNext = i + 1 < timesteps.count ? timesteps[i + 1] : 0
                let velocity = (xT.asType(.float32) - prediction.asType(.float32)) / MLXArray(t)
                xT = (xT.asType(.float32) - MLXArray(t - tNext) * velocity).asType(xT.dtype)
            }
            MLX.eval(xT)
        }

        // Crop the padding back off, in pixel units.
        let outFrames = (trueFrames - 1) * 8 + 1
        let outHeight = trueHeight * 32, outWidth = trueWidth * 32
        var pixels = xT
        if pixels.dim(2) > outFrames || pixels.dim(3) > outHeight || pixels.dim(4) > outWidth {
            pixels = pixels[0..., 0..., 0 ..< outFrames, 0 ..< outHeight, 0 ..< outWidth]
        }

        // [-1, 1] → [0, 1], and [B, C, F, H, W] → [F, H, W, C]
        let frames = MLX.clip((pixels.asType(.float32) + 1) * 0.5, min: 0, max: 1)
        return frames[0].transposed(1, 2, 3, 0)
    }
}

// MARK: - Conditioning heads

/// Sinusoidal timestep projection followed by the two-layer MLP the checkpoint
/// carries (`t_embedder.mlp.0` / `.2`, SiLU between).
public class DiffVAETimestepEmbedder: Module {
    @ModuleInfo(key: "mlp") var mlp: [Linear]

    public init(hiddenDim: Int, projectionDim: Int = 256) {
        self._mlp.wrappedValue = [
            Linear(projectionDim, hiddenDim, bias: true),
            Linear(hiddenDim, hiddenDim, bias: true),
        ]
        super.init()
    }

    public func callAsFunction(_ t: MLXArray, dtype: DType) -> MLXArray {
        let projected = getTimestepEmbedding(timesteps: t, embeddingDim: 256).asType(dtype)
        return mlp[1](MLXNN.silu(mlp[0](projected)))
    }
}

/// One projection shared by every diffusion block, emitting the seven AdaLN-Zero
/// chunks (scale/shift/gate for attention and MLP, plus the context gate).
public class DiffVAESharedAdaLN: Module {
    let dim: Int
    @ModuleInfo(key: "proj") var proj: Linear

    public init(dim: Int, embeddingDim: Int) {
        self.dim = dim
        self._proj.wrappedValue = Linear(
            embeddingDim, DiffVAEDiffusionBlock.adaLNChunks * dim, bias: true)
        super.init()
    }

    /// Returns seven `[B, 1, 1, 1, dim]` chunks.
    public func callAsFunction(_ tEmb: MLXArray) -> [MLXArray] {
        let h = proj(MLXNN.silu(tEmb))
        return (0 ..< DiffVAEDiffusionBlock.adaLNChunks).map { i in
            h[0..., (i * dim) ..< ((i + 1) * dim)]
                .reshaped([h.dim(0), 1, 1, 1, dim])
        }
    }
}
