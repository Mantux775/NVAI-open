// ICLoRAVideoReference.swift - Video-to-video through a reference-conditioned IC-LoRA
// Copyright 2025

import Foundation
@preconcurrency import MLX

extension LTXPipeline {

    /// Re-render a clip with an IC-LoRA that consumes a reference video in context.
    ///
    /// This is the shape LTX's pixel spatial upscaler takes: the reference is the
    /// low-resolution clip, the output is a re-render at `referenceDownscaleFactor`
    /// times its linear resolution, with fine detail **synthesised** rather than
    /// interpolated.
    ///
    /// ## Two stages, and why that matters
    ///
    /// The adapter alone does not produce the output resolution. Following
    /// `ic_lora.py`, a run is:
    ///
    /// 1. a full 8-step denoise **at the reference's own resolution**, with the
    ///    reference appended in context;
    /// 2. the *latent* spatial upscaler applied to that result;
    /// 3. a 3-step refinement at the target resolution with the adapter still
    ///    fused and the reference appended, starting from the upscaled latent
    ///    re-noised to σ ≈ 0.91 rather than from pure noise.
    ///
    /// Step 3 deliberately diverges from `ic_lora.py`, which refines on the bare
    /// transformer (`loras=()`) without the reference. Measured on this port, six
    /// runs across both generations: subject identity survives the σ-0.909 renoise
    /// **only** when adapter and reference are both active in the final stage —
    /// the reference tokens anchor nothing on a model that was never trained to
    /// read them, and either half alone swaps the subject.
    ///
    /// The two upscalers are links in one chain rather than competing options: the
    /// latent one carries geometry across resolutions, the IC-LoRA supplies detail.
    /// Denoising the target resolution from pure noise instead leaves composition
    /// pinned only by the appended tokens, which lets pose and texture wander even
    /// when the framing survives.
    ///
    /// The scale factor is read from the adapter's `reference_downscale_factor`
    /// metadata rather than taken as a parameter, matching how the reference
    /// implementation derives it.
    ///
    /// - Parameters:
    ///   - prompt: describes the scene. The upscaler still conditions on text.
    ///   - referenceVideoPath: the low-resolution clip.
    ///   - loraPath: the IC-LoRA. Fused for the run and unfused afterwards.
    ///   - upscalerWeightsPath: the *latent* spatial upscaler for this generation.
    ///   - config: target geometry. `width`/`height` are the **output** size.
    ///   - loraScale: adapter strength; these weights ship pre-scaled for 1.0.
    ///   - stageOneOutputPath: when set, the stage-1 result is written there at
    ///     reference resolution — what the adapter produced before the upscale, the
    ///     equivalent of the reference implementation's `--skip-stage-2`. Written
    ///     here rather than handed back through a callback because `MLXArray` is
    ///     not `Sendable` and this pipeline is an actor.
    public func generateWithVideoReference(
        prompt: String,
        referenceVideoPath: String,
        loraPath: String,
        upscalerWeightsPath: String,
        config: LTXVideoGenerationConfig,
        loraScale: Float = 1.0,
        onProgress: (@Sendable (GenerationProgress) -> Void)? = nil,
        stageOneOutputPath: String? = nil
    ) async throws -> VideoGenerationResult {
        let startTime = Date()
        try config.validate()
        guard FileManager.default.fileExists(atPath: referenceVideoPath) else {
            throw LTXError.fileNotFound("Reference video not found: \(referenceVideoPath)")
        }

        // The two upscaler families share a name and nothing else. Handing the
        // latent one here would fuse zero layers and silently produce a plain
        // text-to-video generation at the target size — plausible output, wrong
        // operation. Cheaper to refuse it by inspecting the file.
        guard try !LoRALoader.load(from: loraPath).layers.isEmpty else {
            throw LTXError.invalidLoRA(
                "\((loraPath as NSString).lastPathComponent) carries no LoRA layers. The *latent* "
                + "spatial upscaler is a standalone conv model used between generation stages; "
                + "this path needs the *pixel* spatial upscaler IC-LoRA.")
        }

        let downscaleFactor = LoRALoader.referenceDownscaleFactor(from: loraPath)
        guard downscaleFactor >= 1 else {
            throw LTXError.invalidLoRA("reference_downscale_factor must be >= 1")
        }
        // The inter-stage *latent* upscaler is a fixed x2: an x4 adapter would
        // leave stage 2 with a half-sized latent and crash at the re-noise add
        // after minutes of stage-1 compute. Refuse up front until a matching
        // latent chain exists.
        guard downscaleFactor <= 2 else {
            throw LTXError.invalidConfiguration(
                "This adapter's reference_downscale_factor is \(downscaleFactor), but the "
                + "inter-stage latent upscaler is x2-only — x\(downscaleFactor) upscaling "
                + "is not supported yet.")
        }
        guard config.width % downscaleFactor == 0, config.height % downscaleFactor == 0 else {
            throw LTXError.invalidConfiguration(
                "Output \(config.width)x\(config.height) must divide by the adapter's "
                + "reference_downscale_factor (\(downscaleFactor))")
        }
        let referenceWidth = config.width / downscaleFactor
        let referenceHeight = config.height / downscaleFactor

        if !isLoaded { try await loadModels(progressCallback: nil) }
        let beacon = RuntimeBeacon.begin(task: "ic-lora-video", model: model.rawValue)
        defer { beacon?.end() }

        LTXDebug.log("[ic-lora] reference \(referenceWidth)x\(referenceHeight) → output "
            + "\(config.width)x\(config.height) (x\(downscaleFactor)), \(config.numFrames) frames")
        let referenceLatent = try await encodeVideo(
            path: referenceVideoPath,
            width: referenceWidth, height: referenceHeight, numFrames: config.numFrames)

        let encoded = try await encodeText(prompt)
        unloadGemmaIfConfigured()

        // Fuse for stage 1 only — see the note above. The defer is a safety net for
        // the error paths; the normal flow unfuses before stage 2.
        let fusedLayers = try fuseLoRA(from: loraPath, scale: loraScale)
        defer { unfuseLoRA() }
        LTXDebug.log("[ic-lora] fused \(fusedLayers) layer-pairs at scale \(loraScale)")

        guard let transformerConfig = (transformer?.config ?? ltx2Transformer?.config) else {
            throw LTXError.modelNotLoaded("Transformer not loaded")
        }
        guard let decoder = vaeDecoder else {
            throw LTXError.modelNotLoaded("VAE decoder not loaded")
        }

        // ---- Stage 1: denoise at the reference's own resolution ----
        let stage1Shape = VideoLatentShape.fromPixelDimensions(
            batch: 1, channels: 128,
            frames: config.numFrames, height: referenceHeight, width: referenceWidth)
        let stage1Reference = buildVideoReference(
            referenceLatent: referenceLatent,
            targetShape: stage1Shape,
            downscaleFactor: 1,          // reference and stage 1 share a resolution
            hasAudio: false,
            refConfig: transformerConfig)

        let stage1Sigmas = DISTILLED_SIGMA_VALUES
        let stage2Sigmas = STAGE_2_DISTILLED_SIGMA_VALUES
        let totalSteps = (stage1Sigmas.count - 1) + (stage2Sigmas.count - 1)

        var latent = generateNoise(shape: stage1Shape, seed: config.seed)
        MLX.eval(latent)

        for step in 0 ..< (stage1Sigmas.count - 1) {
            let sigma = stage1Sigmas[step]
            onProgress?(GenerationProgress(
                currentStep: step, totalSteps: totalSteps, sigma: sigma, phase: .denoising))
            let velocity = runDenoiseStep(
                sigma: sigma, videoLatent: latent, audioLatentPacked: nil,
                shape: stage1Shape, videoAppendCtx: stage1Reference, audioRefCtx: nil,
                audioNumFrames: 0,
                videoTextEmbeddings: encoded.embeddings,
                audioTextEmbeddings: encoded.embeddings,
                textMask: encoded.mask)
            latent = latent + MLXArray(stage1Sigmas[step + 1] - sigma) * velocity.video
            MLX.eval(latent)
        }

        if let stageOneOutputPath {
            let stage1Frames = decodeFrames(latent: latent)
            MLX.eval(stage1Frames)
            _ = try await VideoExporter.exportVideo(
                frames: stage1Frames, width: referenceWidth, height: referenceHeight,
                fps: 24, to: URL(fileURLWithPath: stageOneOutputPath))
            LTXDebug.log("[ic-lora] stage 1 written to \(stageOneOutputPath)")
        }

        // ---- Latent upscale between the stages ----
        onProgress?(GenerationProgress(
            currentStep: stage1Sigmas.count - 1, totalSteps: totalSteps,
            sigma: 0, phase: .upscaling))
        let upscaler = try loadSpatialUpscaler(from: upscalerWeightsPath)
        let mean5d = decoder.meanOfMeans.reshaped([1, -1, 1, 1, 1])
        let std5d = decoder.stdOfMeans.reshaped([1, -1, 1, 1, 1])
        latent = (upscaler(latent * std5d + mean5d) - mean5d) / std5d
        MLX.eval(latent)
        LTXDebug.log("[ic-lora] upscaled latent \(latent.shape)")

        // ---- Stage 2: refine at the target resolution from the upscaled latent ----
        let stage2Shape = VideoLatentShape.fromPixelDimensions(
            batch: 1, channels: 128,
            frames: config.numFrames, height: config.height, width: config.width)
        // Reference appended at stage-2 scale; the adapter stays fused. See the
        // doc comment — measured, both are required for identity to survive.
        let stage2Reference = buildVideoReference(
            referenceLatent: referenceLatent,
            targetShape: stage2Shape,
            downscaleFactor: downscaleFactor,
            hasAudio: false,
            refConfig: transformerConfig)

        // Re-noise rather than restart: the upscaled latent already carries the
        // composition, and stage 2 only has to add detail at the higher rate.
        let noiseScale = stage2Sigmas[0]
        latent = MLXArray(noiseScale) * generateNoise(shape: stage2Shape, seed: config.seed)
            + MLXArray(1.0 - noiseScale) * latent
        MLX.eval(latent)

        for step in 0 ..< (stage2Sigmas.count - 1) {
            let sigma = stage2Sigmas[step]
            onProgress?(GenerationProgress(
                currentStep: stage1Sigmas.count - 1 + step, totalSteps: totalSteps,
                sigma: sigma, phase: .refinement))
            let velocity = runDenoiseStep(
                sigma: sigma, videoLatent: latent, audioLatentPacked: nil,
                shape: stage2Shape, videoAppendCtx: stage2Reference, audioRefCtx: nil,
                audioNumFrames: 0,
                videoTextEmbeddings: encoded.embeddings,
                audioTextEmbeddings: encoded.embeddings,
                textMask: encoded.mask)
            latent = latent + MLXArray(stage2Sigmas[step + 1] - sigma) * velocity.video
            MLX.eval(latent)
        }

        onProgress?(GenerationProgress(
            currentStep: totalSteps, totalSteps: totalSteps, sigma: 0, phase: .decoding))
        let frames = decodeFrames(latent: latent)
        MLX.eval(frames)

        return VideoGenerationResult(
            frames: frames,
            seed: config.seed ?? 0,
            generationTime: Date().timeIntervalSince(startTime),
            audioWaveform: nil,
            audioSampleRate: nil,
            effectivePrompt: prompt)
    }
}
