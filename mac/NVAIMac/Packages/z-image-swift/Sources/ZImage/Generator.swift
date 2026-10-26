// ZImageGenerator — a loaded-model holder that drives ZImagePipeline.generate and
// returns interleaved RGB8 pixels (the form the engine wrapper serializes to PNG).
// Mirrors ErnieImageGenerator: keeps the wrapper thin and engine-agnostic.

import Foundation
import MLX

public final class ZImageGenerator {

    public let transformer: ZImageTransformer2DModel
    public let vae: AutoencoderKL
    public let textEncoder: ZImageTextEncoder
    public let schedulerShift: Float
    public let schedulerDynamic: Bool
    public let transformerDtype: DType

    public init(
        transformer: ZImageTransformer2DModel,
        vae: AutoencoderKL,
        textEncoder: ZImageTextEncoder,
        schedulerShift: Float,
        schedulerDynamic: Bool,
        transformerDtype: DType
    ) {
        self.transformer = transformer
        self.vae = vae
        self.textEncoder = textEncoder
        self.schedulerShift = schedulerShift
        self.schedulerDynamic = schedulerDynamic
        self.transformerDtype = transformerDtype
    }

    /// Returns interleaved RGB8 pixels + dimensions.
    public func generate(
        prompt: String,
        negativePrompt: String?,
        width: Int,
        height: Int,
        steps: Int,
        guidanceScale: Float,
        seed: UInt64,
        onStep: ((Int, Int) -> Void)? = nil
    ) -> (pixels: [UInt8], width: Int, height: Int) {
        let scheduler = FlowMatchEulerDiscreteScheduler(
            numTrainTimesteps: 1000, shift: schedulerShift, useDynamicShifting: schedulerDynamic)

        let result = ZImagePipeline.generate(
            transformer: transformer, vae: vae, textEncoder: textEncoder, scheduler: scheduler,
            prompt: prompt, height: height, width: width,
            numInferenceSteps: steps, guidanceScale: guidanceScale,
            negativePrompt: negativePrompt,
            seed: seed, transformerDtype: transformerDtype,
            onStep: onStep)

        // image is nil only when the run's task was cancelled (decode skipped); the engine
        // wrapper's post-call checkpoint rethrows before these pixels are consumed.
        guard let image = result.image else { return ([], width, height) }
        return Self.toPixels(image[0], width, height)
    }

    /// img2img: `image` [1,3,H,W] in [-1,1] → clean latent (VAE encode) → renoise at `strength` →
    /// denoise. Returns interleaved RGB8.
    public func generateImg2Img(
        prompt: String, negativePrompt: String?, image: MLXArray,
        width: Int, height: Int, steps: Int, guidanceScale: Float, strength: Float, seed: UInt64,
        onStep: ((Int, Int) -> Void)? = nil
    ) -> (pixels: [UInt8], width: Int, height: Int) {
        let scheduler = FlowMatchEulerDiscreteScheduler(
            numTrainTimesteps: 1000, shift: schedulerShift, useDynamicShifting: schedulerDynamic)
        ZImageProgress.report(.encode)   // the AE encode of the input image; generate() continues it
        let moments = vae.encodeMoments(image)
        let mean = moments[0..., ..<vae.latentChannels, 0..., 0...]
        let clean = (mean - vae.shiftFactor) * vae.scalingFactor
        let result = ZImagePipeline.generate(
            transformer: transformer, vae: vae, textEncoder: textEncoder, scheduler: scheduler,
            prompt: prompt, height: height, width: width,
            numInferenceSteps: steps, guidanceScale: guidanceScale, negativePrompt: negativePrompt,
            seed: seed, img2imgCleanLatent: clean, strength: strength,
            transformerDtype: transformerDtype, onStep: onStep)
        // Cancelled-task decode skip — see generate().
        guard let image = result.image else { return ([], width, height) }
        return Self.toPixels(image[0], width, height)
    }

    /// [-1,1] NCHW [3,H,W] → interleaved RGB8.
    static func toPixels(_ img: MLXArray, _ width: Int, _ height: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let rgb = MLX.clip(img / 2 + 0.5, min: 0, max: 1).transposed(1, 2, 0) * 255
        let u8 = rgb.asType(.uint8)
        eval(u8)
        return (u8.asArray(UInt8.self), width, height)
    }
}
