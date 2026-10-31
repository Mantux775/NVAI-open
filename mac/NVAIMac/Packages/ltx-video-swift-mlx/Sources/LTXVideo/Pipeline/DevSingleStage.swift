// DevSingleStage.swift - Full-quality dev-checkpoint generation (CFG + STG)
// Copyright 2025

import Foundation
@preconcurrency import MLX
import MLXRandom

extension LTXPipeline {

    /// Upstream's DEFAULT_NEGATIVE_PROMPT (ltx-pipelines/utils/constants.py),
    /// verbatim. The CFG direction is trained against these artifact tags; an
    /// empty negative points away from the unconditional mean instead, and at
    /// scale 3.0 from pure noise that measurably erases the prompt's content.
    static let defaultNegativePrompt = """
has_subtitles, has_blurbox, transition from black, transition to black, speech_ending_short, blurry, out of focus, overexposed, underexposed, low contrast, washed out colors, excessive noise, grainy texture, poor lighting, flickering, motion blur, distorted proportions, unnatural skin tones, deformed facial features, asymmetrical face, missing facial features, extra limbs, disfigured hands, wrong hand count, artifacts around text, inconsistent perspective, camera shake, incorrect depth of field, background too sharp, background clutter, distracting reflections, harsh shadows, inconsistent lighting direction, color banding, cartoonish rendering, 3D CGI look, unrealistic materials, uncanny valley effect, incorrect ethnicity, wrong gender, exaggerated expressions, wrong gaze direction, mismatched lip sync, silent or muted audio, distorted voice, robotic voice, echo, background noise, off-sync audio, incorrect dialogue, added dialogue, repetitive speech, jittery movement, awkward pauses, incorrect timing, unnatural transitions, inconsistent framing, tilted camera, flat lighting, inconsistent tone, cinematic oversaturation, stylized filters, or AI artifacts.
"""


    /// Single-stage generation on a dev checkpoint at full quality: 30 steps by
    /// default, classical CFG 3.0 against the official negative prompt, STG on block
    /// 28, guidance rescale 0.7 — the parameters `retake` already uses for dev,
    /// which mirror upstream's `ti2vid_one_stage.py`.
    ///
    /// This exists because the two-stage path is distilled-only by design: its
    /// fixed 8-step schedule is a property of the distilled training, and a dev
    /// checkpoint run through it produces mush (that is what the distilled LoRA
    /// is *for*). Guidance is applied on the denoised x₀, not on velocities,
    /// matching the Lightricks pipelines and the existing retake loop.
    public func generateVideoDev(
        prompt: String,
        config: LTXVideoGenerationConfig,
        onProgress: (@Sendable (GenerationProgress) -> Void)? = nil
    ) async throws -> VideoGenerationResult {
        let startTime = Date()
        try config.validate()
        guard model.isForTraining else {
            throw LTXError.invalidConfiguration(
                "generateVideoDev is for dev checkpoints; \(model.displayName) is distilled — "
                + "use generateVideo, or fuse the distilled LoRA and use generateVideo on dev.")
        }
        if !isLoaded { try await loadModels(progressCallback: nil) }
        let beacon = RuntimeBeacon.begin(task: "generate-dev", model: model.rawValue)
        defer { beacon?.end() }

        // Text conditioning, positive and (for CFG) the official negative.
        let encoded = try await encodeText(prompt, enhance: config.enhancePrompt)
        let negative = try await encodeText(Self.defaultNegativePrompt)
        unloadGemmaIfConfigured()

        // i2v: the conditioning image rides as an appended guide token, exactly as
        // in the two-stage path.
        let shape = VideoLatentShape.fromPixelDimensions(
            batch: 1, channels: 128,
            frames: config.numFrames, height: config.height, width: config.width)
        guard let transformerConfig = (transformer?.config ?? ltx2Transformer?.config) else {
            throw LTXError.modelNotLoaded("Transformer not loaded")
        }
        var appendCtx: AppendKeyframeContext? = nil
        let keyframes: [KeyframeInput] = !config.keyframes.isEmpty
            ? config.keyframes
            : config.imagePath.map { [KeyframeInput(path: $0, pixelFrameIndex: 0)] } ?? []
        if !keyframes.isEmpty {
            let encodedKF = try await encodeKeyframes(
                keyframes, width: config.width, height: config.height)
            appendCtx = prepareKeyframeAppend(
                encoded: encodedKF, shape: shape, hasAudio: false,
                refConfig: transformerConfig, stageLabel: "dev single-stage")
            unloadVAEEncoder()
        }

        // Dev guidance parameters — identical to the retake dev path.
        let cfgScale: Float = 3.0
        let stgScale: Float = 1.0
        let stgBlocks = [28]
        let guidanceRescale: Float = 0.7

        // Token-shifted schedule: unlike the distilled model's fixed sigmas, the
        // dev schedule shifts with the token count.
        let scheduler = LTXScheduler(isDistilled: false)
        scheduler.setTimesteps(
            numSteps: config.numSteps, distilled: false, latentTokenCount: shape.tokenCount)
        let sigmas = scheduler.sigmas
        let numSteps = sigmas.count - 1

        var latent = generateNoise(shape: shape, seed: config.seed)
        MLX.eval(latent)
        LTXDebug.log("[dev] \(numSteps) steps, cfg=\(cfgScale), stg=\(stgScale)@\(stgBlocks), "
            + "rescale=\(guidanceRescale), tokens=\(shape.tokenCount)")

        for step in 0 ..< numSteps {
            let sigma = sigmas[step]
            onProgress?(GenerationProgress(
                currentStep: step, totalSteps: numSteps, sigma: sigma, phase: .denoising))

            // Each pass reuses runDenoiseStep so the appended guide tokens, RoPE
            // extension and velocity cropping stay identical to every other path.
            func denoisedX0(context: MLXArray, mask: MLXArray?) -> MLXArray {
                let velocity = runDenoiseStep(
                    sigma: sigma, videoLatent: latent, audioLatentPacked: nil,
                    shape: shape, videoAppendCtx: appendCtx, audioRefCtx: nil,
                    audioNumFrames: 0,
                    videoTextEmbeddings: context, audioTextEmbeddings: context,
                    textMask: mask)
                return latent - MLXArray(sigma) * velocity.video
            }

            let condX0 = denoisedX0(context: encoded.embeddings, mask: encoded.mask)
            let negX0 = denoisedX0(context: negative.embeddings, mask: negative.mask)

            // STG: perturbed pass with self-attention skipped on the STG blocks.
            transformer?.setSTGBlocks(stgBlocks)
            ltx2Transformer?.setSTGBlocks(stgBlocks)
            let stgX0 = denoisedX0(context: encoded.embeddings, mask: encoded.mask)
            transformer?.clearSTG()
            ltx2Transformer?.clearSTG()

            let combined = LTXPipeline.combineGuidance(
                cond: condX0, neg: negX0, stg: stgX0,
                cfgScale: cfgScale, stgScale: stgScale, guidanceRescale: guidanceRescale)

            // Euler on the recomposed velocity.
            let velocity = (latent - combined) / MLXArray(sigma)
            latent = (latent.asType(.float32)
                + velocity.asType(.float32) * MLXArray(sigmas[step + 1] - sigma))
            MLX.eval(latent)
            if (step + 1) % 5 == 0 { Memory.clearCache() }
        }

        onProgress?(GenerationProgress(
            currentStep: numSteps, totalSteps: numSteps, sigma: 0, phase: .decoding))
        guard vaeDecoder != nil || diffusionVAEDecoder != nil else {
            throw LTXError.modelNotLoaded("VAE decoder not loaded")
        }
        let frames = decodeFrames(latent: latent)
        MLX.eval(frames)

        return VideoGenerationResult(
            frames: frames,
            seed: config.seed ?? 0,
            generationTime: Date().timeIntervalSince(startTime),
            audioWaveform: nil, audioSampleRate: nil,
            effectivePrompt: prompt)
    }
}
