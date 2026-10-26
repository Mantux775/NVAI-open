// Z-Image generation pipeline — isomorphic port of zimage-oracle src/zimage/pipeline.py.
// The pitfall-#11 cluster lives here; every quirk is ported VERBATIM (PORTING-SPEC):
//   1. time reversal: DiT receives (1000 − t)/1000
//   2. model output NEGATED before the Euler step
//   3. pos-anchored CFG: pred = pos + g·(pos − neg)  (do_cfg gate is g > 1.0)
//   4. cfg_truncation (guidance off when t_norm > truncation) + optional
//      cfg_normalization (cap ‖pred‖ at ‖pos‖·factor)
//   5. latents fp32 through the whole loop; DiT in its own dtype; step in fp32
//   6. scheduler.sigmaMin = 0.0 override; skip the final step when t == 0
//   7. text features via ZImageTextEncoder (hidden_states[-2], thinking template)
//   8. VAE denorm: z / scaling_factor + shift_factor, decode fp32
//   9. torch RNG never crosses frameworks — tests inject initLatents; product
//      seeding uses MLXRandom (documented behavioral difference, same distribution)

import Foundation
import MLX
import MLXRandom

public enum ZImagePipeline {

    /// calculate_shift — resolution-dependent mu for dynamic shifting. Both released
    /// checkpoints use static shifting (mu is ignored); ported for config-drivenness.
    public static func calculateShift(
        imageSeqLen: Int,
        baseSeqLen: Int = 256, maxSeqLen: Int = 4096,
        baseShift: Float = 0.5, maxShift: Float = 1.15
    ) -> Float {
        let m = (maxShift - baseShift) / Float(maxSeqLen - baseSeqLen)
        let b = baseShift - m * Float(baseSeqLen)
        return Float(imageSeqLen) * m + b
    }

    public struct GenerateResult {
        public let latents: MLXArray  // final fp32 latents [B, 16, H/8, W/8]
        public let image: MLXArray?   // decoded [-1,1] NCHW, nil for output_type latent
    }

    /// img2img start step (`t_start`), matching diffusers' `get_timesteps` EXACTLY:
    /// `init_timestep = min(steps·strength, steps)`, `t_start = int(max(steps − init_timestep, 0))`.
    /// The floor lands on the *difference*. The naive `steps − int(steps·strength)` floors the product
    /// instead and lands one step too late — e.g. steps=8, strength=0.6: correct=3 (sigma≈0.83), naive=4
    /// (sigma≈0.75). That single step is the difference between an applied edit and a near-identity one
    /// on the distilled 8-step Turbo (few, large denoise jumps).
    public static func img2imgStartStep(numInferenceSteps: Int, strength: Float) -> Int {
        let s = min(max(strength, 0), 1)
        let n = Float(numInferenceSteps)
        return Int(max(n - min(n * s, n), 0))
    }

    /// The number of DiT forwards the denoise loop runs: the steps from `startStep` on (img2img
    /// skips the earlier ones), less a final step at t == 0, which the loop skips. This is the
    /// `totalSteps` the loop reports to `ZImageProgress`.
    public static func denoiseStepCount(timesteps: [Float], startStep: Int) -> Int {
        timesteps.indices.filter { i in
            i >= startStep && !(timesteps[i] == 0 && i == timesteps.count - 1)
        }.count
    }

    /// Mirrors `generate()` in the reference. `initLatents` injects the initial noise
    /// (parity path); when nil, latents are drawn from MLXRandom using `seed`.
    public static func generate(
        transformer: ZImageTransformer2DModel,
        vae: AutoencoderKL?,
        textEncoder: ZImageTextEncoder?,
        scheduler: FlowMatchEulerDiscreteScheduler,
        prompt: String,
        height: Int = 1024,
        width: Int = 1024,
        numInferenceSteps: Int = 8,
        guidanceScale: Float = 0.0,
        negativePrompt: String? = nil,
        cfgNormalization: Float? = nil,
        cfgTruncation: Float = 1.0,
        seed: UInt64 = 0,
        initLatents: MLXArray? = nil,
        // img2img: model-space clean latent = (encodeMean(image) − shift)·scaling; strength in (0,1].
        img2imgCleanLatent: MLXArray? = nil,
        strength: Float = 1.0,
        transformerDtype: DType = .bfloat16,
        decodeImage: Bool = true,
        precomputedPromptEmbeds: MLXArray? = nil,
        onStep: ((Int, Int) -> Void)? = nil
    ) -> GenerateResult {
        // vae_scale = 2^(len(block_out)-1) * 2 = 16 for flux-dev AE
        let vaeScaleFactor = 8
        let vaeScale = vaeScaleFactor * 2
        precondition(height % vaeScale == 0, "height must be divisible by \(vaeScale)")
        precondition(width % vaeScale == 0, "width must be divisible by \(vaeScale)")

        let doClassifierFreeGuidance = guidanceScale > 1.0

        // --- text features (variable-length, reference masked-gather semantics) ---
        ZImageProgress.report(.encode)
        // NVAI-open: features computed before (text encoder already unloaded on small Macs).
        precondition(precomputedPromptEmbeds != nil || textEncoder != nil, "text encoder or prompt features needed")
        let promptEmbeds = precomputedPromptEmbeds ?? textEncoder!.encode(prompt)
        var negativeEmbeds: MLXArray? = nil
        if doClassifierFreeGuidance {
            precondition(textEncoder != nil, "CFG needs the text encoder for the negative prompt")
            negativeEmbeds = textEncoder!.encode(negativePrompt ?? "")
        }
        eval(promptEmbeds)
        if let negativeEmbeds { eval(negativeEmbeds) }

        // --- initial latents, fp32 ---
        let heightLatent = 2 * (height / vaeScale)
        let widthLatent = 2 * (width / vaeScale)
        var latents: MLXArray
        if let initLatents {
            precondition(initLatents.shape == [1, transformer.inChannels, heightLatent, widthLatent])
            latents = initLatents.asType(.float32)
        } else {
            MLXRandom.seed(seed)
            latents = MLXRandom.normal(
                [1, transformer.inChannels, heightLatent, widthLatent], dtype: .float32)
        }

        let imageSeqLen = (heightLatent / 2) * (widthLatent / 2)
        let mu = calculateShift(imageSeqLen: imageSeqLen)
        scheduler.sigmaMin = 0.0
        scheduler.setTimesteps(
            numInferenceSteps: numInferenceSteps,
            mu: scheduler.useDynamicShifting ? mu : nil)

        // img2img: interpolate the clean latent with the noise at the start sigma, and begin the
        // denoise loop at t_start. Match diffusers get_timesteps EXACTLY: the floor is applied to the
        // *difference*, not to steps·strength — `t_start = int(steps − min(steps·strength, steps))`.
        // The naive `steps − int(steps·strength)` floors in the wrong place and starts one step late
        // (less noise injected → distilled Turbo can't escape the input → near-identity edits).
        var startStep = 0
        if let cleanLatent = img2imgCleanLatent {
            startStep = img2imgStartStep(numInferenceSteps: numInferenceSteps, strength: strength)
            let sigmaStart = scheduler.sigmas[startStep]
            latents = (1 - sigmaStart) * cleanLatent.asType(.float32) + sigmaStart * latents
        }

        let timesteps = scheduler.timesteps
        // Progress counts the forwards that actually run (img2img skips the pre-start steps), so
        // a host sees 1/N … N/N rather than a counter that starts part-way or stops short.
        let denoiseSteps = denoiseStepCount(timesteps: timesteps, startStep: startStep)
        var stepsDone = 0
        ZImageProgress.report(.denoise)
        for (i, t) in timesteps.enumerated() {
            // Cooperative cancellation: bail per denoise step (non-throwing core API — the
            // MLXZImage wrapper's post-call `try Task.checkCancellation()` rethrows).
            if Task.isCancelled { break }
            if i < startStep { continue }   // img2img: skip the pre-start steps
            // skip computation when t == 0 on the last step
            if t == 0 && i == timesteps.count - 1 { continue }

            let tNorm = (1000.0 - t) / 1000.0  // time reversal

            var currentGuidanceScale = guidanceScale
            if doClassifierFreeGuidance && cfgTruncation <= 1 && tNorm > cfgTruncation {
                currentGuidanceScale = 0.0
            }
            let applyCFG = doClassifierFreeGuidance && currentGuidanceScale > 0

            let timestep = MLXArray([tNorm] as [Float])
            let latentItem = latents.asType(transformerDtype)[0][0..., .newAxis, 0..., 0...]

            var noisePred: MLXArray
            if applyCFG {
                let outs = transformer(
                    [latentItem, latentItem],
                    t: concatenated([timestep, timestep], axis: 0),
                    capFeats: [promptEmbeds, negativeEmbeds!])
                let pos = outs[0].asType(.float32)
                let neg = outs[1].asType(.float32)
                var pred = pos + currentGuidanceScale * (pos - neg)

                if let cfgNormalization, cfgNormalization > 0 {
                    let oriPosNorm = MLX.sqrt(MLX.sum(pos * pos)).item(Float.self)
                    let newPosNorm = MLX.sqrt(MLX.sum(pred * pred)).item(Float.self)
                    let maxNewNorm = oriPosNorm * cfgNormalization
                    if newPosNorm > maxNewNorm {
                        pred = pred * (maxNewNorm / newPosNorm)
                    }
                }
                noisePred = pred[.newAxis, 0..., 0..., 0..., 0...]
            } else {
                let outs = transformer([latentItem], t: timestep, capFeats: [promptEmbeds])
                noisePred = outs[0].asType(.float32)[.newAxis, 0..., 0..., 0..., 0...]
            }

            // negate + squeeze the F axis, then fp32 Euler step
            noisePred = -noisePred.squeezed(axis: 2)
            latents = scheduler.step(
                modelOutput: noisePred, timestep: t, sample: latents
            ).prevSample
            eval(latents)                    // step boundary: bound the lazy graph
            MLX.Memory.clearCache()          // long-denoise cache discipline (skill rule)
            stepsDone += 1
            ZImageProgress.report(.denoise, step: stepsDone, totalSteps: denoiseSteps)
            onStep?(i + 1, timesteps.count)
        }

        // A cancelled task skips the VAE decode (pre-decode seam) — latents-only result;
        // callers on a cancelled task never consume the image.
        guard decodeImage, let vae, !Task.isCancelled else {
            return GenerateResult(latents: latents, image: nil)
        }

        ZImageProgress.report(.decode)
        let z = latents.asType(.float32) / vae.scalingFactor + vae.shiftFactor
        let image = vae.decode(z)
        eval(image)
        return GenerateResult(latents: latents, image: image)
    }
}
