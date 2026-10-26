// Loaders for the files NVAI-open keeps for LTX-Video 2B:
// - `dit.safetensors`: the transformer from Lightricks' single-file checkpoint (`model.diffusion_model.*`, bf16),
// - `vae-decoder.safetensors`: the VAE decoder and its channel statistics (`vae.decoder.*`, `vae.per_channel_statistics.*`),
// - the T5-XXL encoder in mflux's 4-bit format (MLX affine, group 64) plus the relative position table in float32.

import Foundation
import MLX
import MLXNN

public enum LTXWeights {
    static func loadShards(_ directory: URL) throws -> [String: MLXArray] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var weights: [String: MLXArray] = [:]
        for file in files { weights.merge(try MLX.loadArrays(url: file)) { _, new in new } }
        return weights
    }

    /// Quantize exactly the layers that arrive quantized (`<path>.scales` exists); bits and group size from the shapes.
    static func quantizeLikeCheckpoint(_ model: Module, _ weights: [String: MLXArray]) {
        quantize(model: model, filter: { path, module in
            guard let scales = weights["\(path).scales"], let packed = weights["\(path).weight"] else { return nil }
            let inputDims: Int
            if let linear = module as? Linear {
                inputDims = linear.weight.dim(1)
            } else if let embedding = module as? Embedding {
                inputDims = embedding.weight.dim(1)
            } else {
                return nil
            }
            return (inputDims / scales.dim(1), packed.dim(1) * 32 / inputDims, .affine)
        })
    }

    /// T5 from mflux's `text_encoder_2/` (4 bit) with the float32 position table from `relativeBias`; mflux's own
    /// per-layer copies of that table are 4-bit and are left out. Scales and activations in `dtype`.
    public static func loadT5(directory: URL, relativeBias: URL, dtype: DType = .float32) throws -> T5Encoder {
        var weights = try loadShards(directory).filter { !$0.key.contains("relative_attention_bias") }
        for (key, value) in try MLX.loadArrays(url: relativeBias) { weights[key] = value }
        weights = weights.mapValues { $0.dtype == .uint32 ? $0 : $0.asType(dtype) }
        let model = T5Encoder()
        quantizeLikeCheckpoint(model, weights)
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        return model
    }

    /// Checkpoint name → module path (the rest is identical).
    static func transformerKey(_ key: String) -> String {
        var k = key.hasPrefix("model.diffusion_model.") ? String(key.dropFirst("model.diffusion_model.".count)) : key
        k = k.replacingOccurrences(of: ".to_out.0.", with: ".to_out.")
            .replacingOccurrences(of: ".ff.net.0.proj.", with: ".ff.proj_in.")
            .replacingOccurrences(of: ".ff.net.2.", with: ".ff.proj_out.")
        return k
    }

    /// `layers` < 28 keeps only the first blocks (for checks against a reference with as many).
    public static func loadTransformer(file: URL, dtype: DType = .bfloat16, layers: Int? = nil) throws -> LTXTransformer {
        var config = LTXTransformerConfiguration()
        if let layers { config.layers = layers }
        var weights: [String: MLXArray] = [:]
        for (key, value) in try MLX.loadArrays(url: file) {
            let k = transformerKey(key)
            if k.hasPrefix("transformer_blocks."),
               let i = Int(k.split(separator: ".")[1]), i >= config.layers { continue }
            weights[k] = value.asType(dtype)
        }
        let model = LTXTransformer(config)
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        return model
    }

    /// Conv weights go from PyTorch (O, I, kT, kH, kW) to MLX (O, kT, kH, kW, I).
    public static func loadDecoder(file: URL, dtype: DType = .float32) throws -> LTXVideoDecoder {
        var weights: [String: MLXArray] = [:]
        var stats: [String: MLXArray] = [:]
        for (key, raw) in try MLX.loadArrays(url: file) {
            if key.hasPrefix("vae.per_channel_statistics.") {
                stats[String(key.dropFirst("vae.per_channel_statistics.".count))] = raw.asType(.float32)
                continue
            }
            guard key.hasPrefix("vae.decoder.") else { continue }
            var value = raw
            if key.hasSuffix(".weight"), value.ndim == 5 { value = value.transposed(0, 2, 3, 4, 1) }
            weights[String(key.dropFirst("vae.decoder.".count))] = value.asType(dtype)
        }
        let decoder = LTXVideoDecoder()
        try decoder.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        guard let mean = stats["mean-of-means"], let std = stats["std-of-means"] else {
            throw NSError(domain: "LTXV", code: 1, userInfo: [NSLocalizedDescriptionKey: "per_channel_statistics missing"])
        }
        decoder.statistics.mean = mean
        decoder.statistics.std = std
        eval(decoder)
        return decoder
    }

    /// The encoder's 3D kernels (O, I, kT, kH, kW) summed over time into 2D kernels (O, kH, kW, I) – exact for one
    /// frame, see `LTXImageEncoder` – stored with the channel statistics in float16: a third of the 1.39 GB.
    public static func convertImageEncoder(raw: URL, to target: URL) throws {
        var out: [String: MLXArray] = [:]
        for (key, value) in try MLX.loadArrays(url: raw) {
            if key.hasPrefix("vae.per_channel_statistics.") {
                out[key] = value.asType(.float32)
            } else if key.hasPrefix("vae.encoder.") {
                let w = value.ndim == 5 ? value.asType(.float32).sum(axis: 2).transposed(0, 2, 3, 1) : value
                out[key] = w.asType(.float16)
                eval(out[key]!)
            }
        }
        try MLX.save(arrays: out, url: target)
    }

    /// The image encoder from a converted file (2D kernels) or straight from the checkpoint's 3D kernels.
    /// `config`: the checkpoint's `vae` section (`encoder_blocks`); without it the 0.9.5–0.9.8 layout.
    public static func loadImageEncoder(file: URL, config: [String: Any]? = nil,
                                        dtype: DType = .float32) throws -> LTXImageEncoder {
        var weights: [String: MLXArray] = [:]
        var stats: [String: MLXArray] = [:]
        for (key, value) in try MLX.loadArrays(url: file) {
            if key.hasPrefix("vae.per_channel_statistics.") {
                stats[String(key.dropFirst("vae.per_channel_statistics.".count))] = value.asType(.float32)
            } else if key.hasPrefix("vae.encoder.") {
                let w = value.ndim == 5 ? value.asType(.float32).sum(axis: 2).transposed(0, 2, 3, 1) : value
                weights[String(key.dropFirst("vae.encoder.".count))] = w.asType(dtype)
            }
        }
        guard let mean = stats["mean-of-means"], let std = stats["std-of-means"] else {
            throw NSError(domain: "LTXV", code: 1, userInfo: [NSLocalizedDescriptionKey: "per_channel_statistics missing"])
        }
        let blocks = config.flatMap { LTXImageEncoder.blocks(config: $0) } ?? LTXImageEncoder.defaultBlocks
        let missing = LTXImageEncoder.convNames(blocks).filter { weights["\($0).conv.weight"] == nil || weights["\($0).conv.bias"] == nil }
        guard missing.isEmpty else {
            throw NSError(domain: "LTXV", code: 2, userInfo: [NSLocalizedDescriptionKey: "image encoder: missing \(missing.prefix(3))"])
        }
        eval(Array(weights.values))
        return LTXImageEncoder(weights: weights, blocks: blocks, meanOfMeans: mean, stdOfMeans: std)
    }
}
