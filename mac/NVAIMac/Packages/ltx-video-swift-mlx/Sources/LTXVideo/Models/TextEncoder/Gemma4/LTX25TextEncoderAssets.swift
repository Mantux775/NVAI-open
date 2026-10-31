// LTX25TextEncoderAssets.swift - Reading the LTX-2.5 text-encoder bundle
// Copyright 2025

import Foundation
@preconcurrency import MLX
import Gemma4Swift

/// Reader for `text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors`.
///
/// LTX-2.5 ships its whole text stack as one self-contained file: the Gemma 4
/// weights, the Gemma config (in the safetensors `__metadata__`), the tokenizer
/// assets (as byte tensors) and the LTX aggregate projections. Nothing else is
/// downloaded — unlike LTX-2.3, whose encoder is stock Gemma 3 pulled from
/// `mlx-community`.
///
/// The Gemma checkpoint is a derivative (`gemma4-12b-ltx-v1`), not stock Gemma 4:
/// the transformer checkpoint names it in `gemma_source_checkpoint`, and pairing
/// a different Gemma root with it yields garbage, not degraded output — hence
/// ``verifyPairing(withTransformerMetadata:)``.
struct LTX25TextEncoderAssets: @unchecked Sendable {
    // @unchecked: immutable struct over lazily-mmap'd MLXArrays that are only
    // ever read; it crosses from the pipeline actor into the encoder's async
    // loader without concurrent mutation.
    /// Every tensor in the file, lazily mmap'd by MLX.
    private let weights: [String: MLXArray]

    /// The file's safetensors `__metadata__`.
    let metadata: [String: String]

    let fileURL: URL

    // MARK: - Keys

    /// Byte-tensor holding `tokenizer.json`.
    private static let tokenizerJSONKey = "tokenizer_json"

    /// Prefix for the HuggingFace side-car assets stored as byte tensors.
    private static let assetPrefix = "hf_asset__"

    /// Prefix of the Gemma language-model weights inside the bundle.
    private static let gemmaPrefix = "model."

    /// Prefix of the LTX aggregate projections.
    private static let projectionPrefix = "text_embedding_projection."

    // MARK: - Init

    init(fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LTXError.fileNotFound("LTX-2.5 text encoder not found: \(fileURL.path)")
        }
        self.fileURL = fileURL
        let (weights, metadata) = try MLX.loadArraysAndMetadata(url: fileURL)
        self.weights = weights
        self.metadata = metadata
    }

    // MARK: - Config

    /// The `gemma_config` blob, as shipped in the file's metadata.
    private func gemmaConfigData() throws -> Data {
        guard let raw = metadata["gemma_config"], let data = raw.data(using: .utf8) else {
            throw LTXError.weightLoadingFailed(
                "\(fileURL.lastPathComponent) carries no `gemma_config` metadata — "
                + "is this an LTX-2.5 text encoder?")
        }
        return data
    }

    /// Gemma version declared by the encoder, e.g. `gemma4-12b-ltx-v1`.
    var gemmaVersion: String? {
        guard let data = try? gemmaConfigData(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["gemma_version"] as? String
    }

    /// Text-model configuration for the bundled Gemma 4.
    ///
    /// The blob is a `gemma4_unified` config carrying vision and audio sections
    /// this encoder never runs — prompt encoding only needs the text stack. Only
    /// `text_config` is handed to the decoder: routing through the full
    /// `Gemma4Config` would make it attempt the vision/audio sections, whose
    /// reduced schema fails to decode and logs a scary-looking (but harmless)
    /// fallback on every single run.
    func textConfig() throws -> Gemma4TextConfig {
        let data = try gemmaConfigData()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let textSection = root["text_config"],
              let textData = try? JSONSerialization.data(withJSONObject: textSection) else {
            throw LTXError.weightLoadingFailed(
                "The bundled Gemma config has no `text_config` section")
        }
        do {
            return try JSONDecoder().decode(Gemma4TextConfig.self, from: textData)
        } catch {
            throw LTXError.weightLoadingFailed(
                "Could not decode the bundled Gemma text config: \(error)")
        }
    }

    /// Verify that this encoder is the one the transformer checkpoint was trained with.
    ///
    /// LTX-2.5 transformers declare `gemma_source_checkpoint = {ltx_version, gemma_version}`.
    /// Older checkpoints declare nothing, in which case there is nothing to check.
    func verifyPairing(withTransformerMetadata transformerMetadata: [String: String]) throws {
        guard let raw = transformerMetadata["gemma_source_checkpoint"],
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expected = json["gemma_version"] as? String else {
            return
        }
        guard let declared = gemmaVersion else {
            throw LTXError.weightLoadingFailed(
                "The transformer expects Gemma \(expected) but \(fileURL.lastPathComponent) "
                + "declares no gemma_version.")
        }
        guard declared == expected else {
            throw LTXError.weightLoadingFailed(
                "Text-encoder mismatch: the transformer was trained against Gemma "
                + "\(expected), this encoder is \(declared). The connector consumes every "
                + "Gemma hidden state, so a mismatched root produces garbage, not degraded output.")
        }
    }

    // MARK: - Tokenizer assets

    /// Write `tokenizer.json` and its side-cars to `directory` and return it.
    ///
    /// The tokenizer lives inside the safetensors as uint8 tensors, so it is
    /// extracted once into a small cache directory that `AutoTokenizer` can read.
    /// Idempotent: an existing, non-empty `tokenizer.json` is left alone.
    @discardableResult
    func materializeTokenizer(in directory: URL) throws -> URL {
        let tokenizerJSON = directory.appendingPathComponent("tokenizer.json")
        if let size = try? FileManager.default.attributesOfItem(atPath: tokenizerJSON.path)[.size] as? Int,
           size > 0 {
            return directory
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let tokenizerTensor = weights[Self.tokenizerJSONKey] else {
            throw LTXError.weightLoadingFailed(
                "\(fileURL.lastPathComponent) carries no `\(Self.tokenizerJSONKey)` tensor")
        }
        try Self.writeByteTensor(tokenizerTensor, to: tokenizerJSON)

        // hf_asset__tokenizer_config.json → tokenizer_config.json, etc.
        for (key, value) in weights where key.hasPrefix(Self.assetPrefix) {
            let name = String(key.dropFirst(Self.assetPrefix.count))
            try Self.writeByteTensor(value, to: directory.appendingPathComponent(name))
        }

        return directory
    }

    /// Materialize a uint8 tensor as a file.
    private static func writeByteTensor(_ tensor: MLXArray, to url: URL) throws {
        let bytes = tensor.asType(.uint8).asArray(UInt8.self)
        try Data(bytes).write(to: url, options: .atomic)
    }

    // MARK: - Weights

    /// Gemma 4 weights, keyed for `Gemma4LLMModel`'s parameter tree.
    ///
    /// The bundle stores them in HuggingFace layout (`model.layers.…`); the Swift
    /// model nests the same tree one level deeper, under `language_model.model.`.
    /// Non-Gemma tensors — the LTX projections, the vision tower, the multimodal
    /// and audio projectors, the tokenizer blobs — are dropped here.
    func gemmaWeights() -> [String: MLXArray] {
        var mapped: [String: MLXArray] = [:]
        mapped.reserveCapacity(weights.count)
        for (key, value) in weights where key.hasPrefix(Self.gemmaPrefix) {
            mapped["language_model." + key] = value
        }
        return mapped
    }

    /// LTX aggregate projections, keyed for ``GemmaFeaturesExtractor``.
    ///
    /// Shapes are unchanged from LTX-2.3 (`[4096, 188160]` = 49 hidden states ×
    /// 3840), so the Feature-Extractor-V2 path carries over untouched; only the
    /// language model underneath differs.
    func projectionWeights() -> [String: MLXArray] {
        var raw: [String: MLXArray] = [:]
        for (key, value) in weights where key.hasPrefix(Self.projectionPrefix) {
            raw[key] = value
        }
        return LTXWeightLoader.mapTextEncoderWeights(raw)
    }
}
