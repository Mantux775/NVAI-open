// SPDX-License-Identifier: MIT (port). SeedVR2 model/weights: Apache-2.0 / ByteDance.
//
// Core SeedVR2 upscale: encode -> (noise + condition) -> 1-step transformer -> scheduler
// step -> decode. Preprocess (bicubic resize / softness) and LAB color-correction are
// host responsibilities (ForgeUpscaler / utilities) — this is the model critical path.
// Tiling for large images is delegated to the host (e.g. ForgeUpscaler.MLXTileProcessor).
import Foundation
import MLX
import MLXNN

public final class SeedVR2Upscaler {
    public let vae: SeedVR2VAE
    public let transformer: SeedVR2Transformer
    let textEmb: MLXArray   // [1,58,5120] precomputed positive embedding
    let config: SeedVR2Config

    /// Download + load from an HF repo id (e.g. `mlx-community/SeedVR2-3B-mlx-int8`).
    public convenience init(repoId: String, revision: String = "main") throws {
        try self.init(weights: SeedVR2Weights.from(repoId: repoId, revision: revision))
    }

    public convenience init(directory dir: URL) throws {
        try self.init(weights: SeedVR2Weights(directory: dir))
    }

    public init(weights w: SeedVR2Weights) throws {
        self.config = w.config
        self.transformer = SeedVR2Transformer(w.config)
        if let q = w.quantization {
            // Apply the same quantization the weights were saved with, then load.
            SeedVR2Quant.quantizeTransformer(transformer, groupSize: q.groupSize, bits: q.bits)
        }
        try transformer.update(parameters: ModuleParameters.unflattened(w.transformer), verify: .none)
        self.vae = SeedVR2VAE()
        try vae.update(parameters: ModuleParameters.unflattened(w.vae), verify: .none)
        self.textEmb = w.posEmb
        eval(transformer, vae)
    }

    /// processedImage: [B,3,H,W] (or [B,3,1,H,W]) in [-1,1], dims padded to /16.
    /// Returns the decoded latent image [B,3,H*?,W*?] (pre-crop, pre-color-correct).
    public func upscale(processedImage: MLXArray, seed: UInt64, numSteps: Int = 1) -> MLXArray {
        let initial = vae.encode(processedImage)                 // [B,16,1,h,w]
        let condition = SeedVR2LatentCreator.condition(initial)  // [B,17,1,h,w]
        var latents = SeedVR2LatentCreator.noiseLatents(seed: seed, height: initial.shape[3], width: initial.shape[4])

        let scheduler = SeedVR2EulerScheduler(numInferenceSteps: numSteps)
        for t in 0 ..< scheduler.numSteps {
            let modelInput = concatenated([latents, condition], axis: 1)   // [B,33,1,h,w]
            let pred = transformer(modelInput, textEmb, timestep: scheduler.timesteps[t])
            latents = scheduler.step(noise: pred, timestepIdx: t, latents: latents)
            eval(latents)
        }
        return vae.decode(latents)
    }
}
