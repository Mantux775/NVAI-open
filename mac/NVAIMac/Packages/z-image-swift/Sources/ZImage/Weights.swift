// Weight loading for ZImageTransformer2DModel — mirrors src/utils/loader.py.
// All upstream→Swift key remapping lives HERE (skill rule: sanitize in the loader,
// never the constructor, never first forward). Each remap corresponds to a documented
// structural deviation in Transformer.swift's header.

import Foundation
import MLX
import MLXNN

public enum ZImageWeights {

    /// Precision-sensitive DiT projections kept at bf16 when quantizing (Lens doctrine:
    /// skipping in/out embeds, time embed, final layer, and per-block modulation lifts
    /// int4 quality at the same size). Everything else (attention + FFN Linears in the
    /// 30 main blocks and 4 refiners — the bulk of the 6B) is quantized.
    static func keepHiPrecision(path: String) -> Bool {
        let keepPrefixes = [
            "x_embedder",           // patch in-embed
            "final_layer",          // out projection + its AdaLN
            "t_embedder",           // timestep MLP
            "cap_embedder_linear",  // caption in-projection
        ]
        if keepPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        // per-block AdaLN modulation (small, precision-sensitive scale/gate producer)
        if path.hasSuffix("adaLN_modulation.0") { return true }
        return false
    }

    /// Quantize a loaded DiT in place (affine, group 64) skipping keepHiPrecision layers.
    public static func quantizeDiT(_ model: ZImageTransformer2DModel, bits: Int, groupSize: Int = 64) {
        quantize(model: model, filter: { path, module in
            guard module is Linear else { return nil }   // norms/params untouched
            if keepHiPrecision(path: path) { return nil }
            return (groupSize, bits, .affine)
        })
        eval(model)
    }

    /// Upstream safetensors key → Swift module path. Order matters (prefix rewrites).
    static let ditKeyRemaps: [(prefix: String, replacement: String)] = [
        ("all_x_embedder.2-1.", "x_embedder."),
        ("all_final_layer.2-1.", "final_layer."),
        ("final_layer.adaLN_modulation.1.", "final_layer.adaLN_linear."),
        ("t_embedder.mlp.0.", "t_embedder.mlp_in."),
        ("t_embedder.mlp.2.", "t_embedder.mlp_out."),
        ("cap_embedder.0.", "cap_embedder_norm."),
        ("cap_embedder.1.", "cap_embedder_linear."),
    ]

    static func remapDiTKey(_ key: String) -> String {
        var key = key
        for (prefix, replacement) in ditKeyRemaps where key.hasPrefix(prefix) {
            key = replacement + key.dropFirst(prefix.count)
            break
        }
        // final_layer remap above only fires post all_final_layer rewrite:
        if key.hasPrefix("final_layer.adaLN_modulation.1.") {
            key = "final_layer.adaLN_linear." + key.dropFirst("final_layer.adaLN_modulation.1.".count)
        }
        return key
    }

    /// Load every *.safetensors shard in a directory into one flat dict.
    static func loadShards(directory: URL) throws -> [String: MLXArray] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "safetensors" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        precondition(!files.isEmpty, "no safetensors shards in \(directory.path)")

        var weights: [String: MLXArray] = [:]
        for file in files {
            let shard = try MLX.loadArrays(url: file)
            weights.merge(shard) { _, new in new }
        }
        return weights
    }

    /// Load the DiT from `<snapshot>/transformer/`, strict (`verify: .all`).
    /// Turbo ships fp32 shards, Base bf16 — pass `dtype` to unify (nil = keep source).
    public static func loadTransformer(
        snapshotPath: String,
        dtype: DType? = .bfloat16
    ) throws -> ZImageTransformer2DModel {
        let dir = URL(fileURLWithPath: snapshotPath).appendingPathComponent("transformer")
        var weights = try loadShards(directory: dir)

        weights = Dictionary(uniqueKeysWithValues: weights.map { key, value in
            (remapDiTKey(key), dtype.map { value.asType($0) } ?? value)
        })

        let model = ZImageTransformer2DModel()
        let parameters = ModuleParameters.unflattened(weights)
        try model.update(parameters: parameters, verify: [.all])
        eval(model)
        return model
    }

    /// Load the FLUX.1-dev AE from `<snapshot>/vae/` — fp32 (config `force_upcast: true`).
    /// Conv2d weights transpose PT (O,I,kH,kW) → MLX (O,kH,kW,I) here.
    public static func loadVAE(
        snapshotPath: String,
        dtype: DType = .float32
    ) throws -> AutoencoderKL {
        let dir = URL(fileURLWithPath: snapshotPath).appendingPathComponent("vae")
        let cfg = try ZImageVAEConfig.load(dir.appendingPathComponent("config.json"))
        let vae = AutoencoderKL(cfg)

        var weights: [String: MLXArray] = [:]
        for (key, rawValue) in try loadShards(directory: dir) {
            var value = rawValue
            if key.hasSuffix(".weight"), value.ndim == 4 {
                value = value.transposed(0, 2, 3, 1)
            }
            weights[key] = value.asType(dtype)
        }
        try vae.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(vae)
        return vae
    }

    /// Load the Qwen3-4B hidden-state encoder from `<snapshot>/text_encoder/`.
    /// The encoder runs (n−1) layers for hidden_states[-2]; the checkpoint's last-layer,
    /// final-norm, and (tied) lm_head keys are intentionally dropped here.
    public static func loadTextEncoder(
        snapshotPath: String,
        dtype: DType? = .bfloat16
    ) throws -> Qwen3HiddenStateEncoder {
        let dir = URL(fileURLWithPath: snapshotPath).appendingPathComponent("text_encoder")
        let config = try Qwen3EncoderConfiguration.load(dir.appendingPathComponent("config.json"))
        let lastLayerPrefix = "model.layers.\(config.hiddenLayers - 1)."

        var weights: [String: MLXArray] = [:]
        for (key, value) in try loadShards(directory: dir) {
            guard key.hasPrefix("model.") else { continue }        // drops lm_head.* if present
            let stripped = String(key.dropFirst("model.".count))
            if key.hasPrefix(lastLayerPrefix) || stripped.hasPrefix("norm.") { continue }
            weights[stripped] = dtype.map { value.asType($0) } ?? value
        }

        let encoder = Qwen3HiddenStateEncoder(config)
        try encoder.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(encoder)
        return encoder
    }
}

// MARK: - NVAI-open: mflux-community checkpoints (pre-quantized, MLX affine)

/// Loaders for `mflux-community/z-image-turbo-mflux-q4` (5.9 GB instead of 20.5 GB in bf16). The layers arrive
/// quantized (`weight` packed as uint32 plus `scales`/`biases`); mflux names a few modules differently and ships
/// no config.json for the text encoder and the VAE.
extension ZImageWeights {
    /// Qwen3-4B, the Z-Image text encoder (values from its config.json on Hugging Face).
    public static let qwen3_4B = Qwen3EncoderConfiguration(
        hiddenSize: 2560, hiddenLayers: 36, intermediateSize: 9728, attentionHeads: 32, rmsNormEps: 1e-6,
        vocabularySize: 151_936, kvHeads: 8, ropeTheta: 1_000_000, headDim: 128, maxPositionEmbeddings: 40_960)

    /// The FLUX.1-dev autoencoder Z-Image decodes with.
    public static let fluxAE = ZImageVAEConfig(
        inChannels: 3, outChannels: 3, latentChannels: 16, blockOutChannels: [128, 256, 512, 512],
        layersPerBlock: 2, normNumGroups: 32, scalingFactor: 0.3611, shiftFactor: 0.1159)

    /// mflux key → Swift module path (after mflux's own names).
    static let mfluxDiTRemaps: [(prefix: String, replacement: String)] = [
        ("all_x_embedder.2-1.", "x_embedder."),
        ("all_final_layer.2-1.adaLN_modulation.0.", "final_layer.adaLN_linear."),
        ("all_final_layer.2-1.", "final_layer."),
        ("t_embedder.linear1.", "t_embedder.mlp_in."),
        ("t_embedder.linear2.", "t_embedder.mlp_out."),
        ("cap_embedder.0.", "cap_embedder_norm."),
        ("cap_embedder.1.", "cap_embedder_linear."),
    ]

    /// Floating-point arrays to `dtype`; the packed uint32 weights stay as they are.
    static func cast(_ weights: [String: MLXArray], to dtype: DType) -> [String: MLXArray] {
        weights.mapValues { $0.dtype == .uint32 ? $0 : $0.asType(dtype) }
    }

    /// Quantize exactly the layers that arrive quantized (a `<path>.scales` key exists), with the bits and group
    /// size read from the packed shapes: in = packed columns · 32 / bits, group size = in / scales columns.
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

    /// The DiT from `<snapshot>/transformer/` (mflux names, pre-quantized), strict. mflux quantizes every Linear,
    /// also the ones `keepHiPrecision` keeps at bf16 (in/out embeds, time embed, final layer, AdaLN modulation);
    /// at 4 bits that shows as a 16-px patch grid and shifted colours. `precise` is a safetensors file with those
    /// layers in bf16 under upstream names: they replace the quantized ones, as in the port's own int4 tier.
    public static func loadMFluxTransformer(directory: URL, precise: URL? = nil,
                                            dtype: DType = .bfloat16) throws -> ZImageTransformer2DModel {
        var weights: [String: MLXArray] = [:]
        for (key, value) in try loadShards(directory: directory) {
            var mapped = key
            for (prefix, replacement) in mfluxDiTRemaps where mapped.hasPrefix(prefix) {
                mapped = replacement + mapped.dropFirst(prefix.count)
                break
            }
            weights[mapped] = value
        }
        if let precise {
            var replacement: [String: MLXArray] = [:]
            for (key, value) in try MLX.loadArrays(url: precise) { replacement[remapDiTKey(key)] = value }
            func module(_ key: String) -> String { key.lastIndex(of: ".").map { String(key[..<$0]) } ?? key }
            let replaced = Set(replacement.keys.map(module))
            weights = weights.filter { !replaced.contains(module($0.key)) }
            weights.merge(replacement) { _, new in new }
        }
        let model = ZImageTransformer2DModel()
        quantizeLikeCheckpoint(model, weights)
        try model.update(parameters: ModuleParameters.unflattened(cast(weights, to: dtype)), verify: [.all])
        eval(model)
        return model
    }

    /// The Qwen3-4B hidden-state encoder from `<snapshot>/text_encoder/` (no `model.` prefix in mflux). As in
    /// `loadTextEncoder`, the last layer and the final norm are dropped (hidden_states[-2]).
    public static func loadMFluxTextEncoder(directory: URL, dtype: DType = .bfloat16) throws -> Qwen3HiddenStateEncoder {
        let config = qwen3_4B
        let lastLayerPrefix = "layers.\(config.hiddenLayers - 1)."
        var weights: [String: MLXArray] = [:]
        for (key, value) in try loadShards(directory: directory) {
            let stripped = key.hasPrefix("model.") ? String(key.dropFirst("model.".count)) : key
            if stripped.hasPrefix(lastLayerPrefix) || stripped.hasPrefix("norm.") || stripped.hasPrefix("lm_head.") { continue }
            // mflux stores the precomputed RoPE frequencies (no weights; MLXNN's RoPE computes them).
            if stripped.hasPrefix("rotary_emb") { continue }
            weights[stripped] = value
        }
        let encoder = Qwen3HiddenStateEncoder(config)
        quantizeLikeCheckpoint(encoder, weights)
        try encoder.update(parameters: ModuleParameters.unflattened(cast(weights, to: dtype)), verify: [.all])
        eval(encoder)
        return encoder
    }

    /// The FLUX.1 AE from `<snapshot>/vae/` (conv weights already in MLX layout). mflux wraps conv_in and conv_out
    /// in one more level (`conv` in the decoder, `conv2d` in the encoder) and conv_norm_out in `norm`.
    public static func loadMFluxVAE(directory: URL, dtype: DType = .float32) throws -> AutoencoderKL {
        var weights: [String: MLXArray] = [:]
        for (key, value) in try loadShards(directory: directory) {
            let mapped = key
                .replacingOccurrences(of: ".conv_in.conv.", with: ".conv_in.")
                .replacingOccurrences(of: ".conv_in.conv2d.", with: ".conv_in.")
                .replacingOccurrences(of: ".conv_out.conv.", with: ".conv_out.")
                .replacingOccurrences(of: ".conv_out.conv2d.", with: ".conv_out.")
                .replacingOccurrences(of: ".conv_norm_out.norm.", with: ".conv_norm_out.")
            weights[mapped] = value
        }
        let vae = AutoencoderKL(fluxAE)
        quantizeLikeCheckpoint(vae, weights)
        try vae.update(parameters: ModuleParameters.unflattened(cast(weights, to: dtype)), verify: [.all])
        eval(vae)
        return vae
    }
}
