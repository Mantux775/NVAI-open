// Text (or a start image) to video with the distilled LTX-Video 2B: rectified flow, eight Euler steps on the
// checkpoint's own timesteps, no guidance. The model predicts the velocity (noise − clean), so
// x(σ_next) = x(σ) + (σ_next − σ) · v.

import Foundation
import MLX
import MLXRandom

public enum LTXPipeline {
    /// `allowed_inference_steps` of ltxv-2b-0.9.8-distilled; the last step goes from 0.4219 to 0.
    public static let distilledSigmas: [Float] = [1.0, 0.9937, 0.9875, 0.9812, 0.975, 0.9094, 0.725, 0.4219]

    /// Latent voxels for a video of `frames` (8n + 1) × `height` × `width` (multiples of 32).
    public static func latentShape(frames: Int, height: Int, width: Int) -> (f: Int, h: Int, w: Int) {
        ((frames - 1) / 8 + 1, height / 32, width / 32)
    }

    /// Noise on the start image latent in every step, scaled by σ² (`image_cond_noise_scale` in Lightricks' inference
    /// config; "helps with motion continuity, especially when conditioned on a single frame"). Measured on two clips
    /// (768 × 512, 49 frames): 12 % and 1 % more motion than without, just as smooth.
    public static let imageNoiseScale: Float = 0.15

    /// Latents [1, 128, F, H, W] (float32) after all steps. `context`: T5 features [1, L, 4096].
    /// `startImage`: the encoded start image [1, 128, 1, H, W] (image to video). Its tokens get timestep 0 and are never
    /// denoised: before every step the first latent frame becomes the start image plus `imageNoiseScale` · σ² of fresh
    /// noise and keeps that value through the step, as in Lightricks' pipeline (hard conditioning). ComfyUI's
    /// LTXVImgToVideo with strength 1 is the same without the noise.
    public static func denoise(transformer: LTXTransformer, context: MLXArray, frames: Int, height: Int, width: Int,
                               frameRate: Float, seed: UInt64, sigmas: [Float] = distilledSigmas,
                               startImage: MLXArray? = nil, imageNoiseScale: Float = imageNoiseScale,
                               onStep: ((Int, Int) -> Void)? = nil) -> MLXArray {
        let (f, h, w) = latentShape(frames: frames, height: height, width: width)
        let channels = transformer.config.inChannels
        MLXRandom.seed(seed)
        var latents = MLXRandom.normal([1, channels, f, h, w], dtype: .float32)
        let start = startImage?.asType(.float32)
        func withFirstFrame(_ first: MLXArray, _ x: MLXArray) -> MLXArray {
            // split instead of subscripts: subscripting crashed on arrays with more than three axes.
            f > 1 ? concatenated([first, split(x, indices: [1], axis: 2)[1]], axis: 2) : first
        }
        let conditioned = start == nil ? 0 : h * w
        let rope = transformer.rope(frames: f, height: h, width: w, frameRate: frameRate)
        let schedule = sigmas + [0]
        for i in 0 ..< sigmas.count {
            if Task.isCancelled { break }
            var first: MLXArray?
            if let start {
                let sigma = schedule[i]
                first = imageNoiseScale > 0
                    ? start + (imageNoiseScale * sigma * sigma) * MLXRandom.normal(start.shape, dtype: .float32) : start
                latents = withFirstFrame(first!, latents)
            }
            let tokens = latents.transposed(0, 2, 3, 4, 1).reshaped(1, f * h * w, channels)
            let velocity = transformer(tokens, sigma: schedule[i], context: context, rope: rope,
                                       conditionedTokens: conditioned)
                .asType(.float32).reshaped(1, f, h, w, channels).transposed(0, 4, 1, 2, 3)
            latents = latents + (schedule[i + 1] - schedule[i]) * velocity
            if let first { latents = withFirstFrame(first, latents) }
            eval(latents)
            Memory.clearCache()
            onStep?(i + 1, sigmas.count)
        }
        return latents
    }

    /// Lightricks' `tone_map_latents`, applied right before decoding (13B 0.9.8: compression 0.6, in the
    /// checkpoint's pipeline config): a sigmoid pulls large latent values towards smaller ones, small ones stay.
    public static func toneMap(_ latents: MLXArray, compression: Float) -> MLXArray {
        guard compression > 0 else { return latents }
        let s = compression * 0.75
        let sigmoidTerm = sigmoid(4 * s * (abs(latents) - 1))
        return latents * (1 - 0.8 * s * sigmoidTerm)
    }

    /// Decode noise like the reference (`randn_like` · 0.025), drawn from its own seed.
    public static func decodeNoise(like latents: MLXArray, seed: UInt64) -> MLXArray {
        MLXRandom.seed(seed &+ 0x5EED)
        return MLXRandom.normal(latents.shape, dtype: .float32)
    }

    /// [1, F, H, W, 3] in [−1, 1] → RGB bytes per frame.
    public static func frames(_ video: MLXArray) -> [[UInt8]] {
        let u8 = (clip(video[0].asType(.float32) / 2 + 0.5, min: 0, max: 1) * 255 + 0.5).asType(.uint8)
        eval(u8)
        let f = u8.dim(0), size = u8.dim(1) * u8.dim(2) * 3
        let all = u8.asArray(UInt8.self)
        return (0 ..< f).map { Array(all[($0 * size) ..< (($0 + 1) * size)]) }
    }
}
