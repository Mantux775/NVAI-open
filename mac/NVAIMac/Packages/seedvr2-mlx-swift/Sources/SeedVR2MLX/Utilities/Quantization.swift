// SPDX-License-Identifier: MIT (port). SeedVR2 model/weights: Apache-2.0 / ByteDance.
//
// int8 quantization of the SeedVR2 transformer (DiT). int8 is near-lossless for this model
// (benchmark: 50.3 dB / cosine ~0.9999); int4 degrades it (22.7 dB) — so int8 is the
// on-device target. The VAE is kept at fp16 (small + precision-sensitive).
import MLX
import MLXNN

public enum SeedVR2Quant {
    /// Quantize the transformer's Linear layers in place. Skips any Linear whose input
    /// dimension isn't divisible by `groupSize` (e.g. `vid_in.proj` at in=132) — those
    /// stay fp16. Use the IDENTICAL call on save and load so the same layers are quantized.
    public static func quantizeTransformer(_ model: SeedVR2Transformer, groupSize: Int = 64, bits: Int = 8) {
        quantize(model: model, groupSize: groupSize, bits: bits) { _, m in
            guard let lin = m as? Linear else { return false }
            return (lin.weight.shape.last ?? 0) % groupSize == 0
        }
    }
}
