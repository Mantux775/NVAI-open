// Gemma3Encoder.swift - LTX-2.3 prompt encoding on Gemma 3
// Copyright 2025

import Foundation
@preconcurrency import MLX
import Tokenizers

/// LTX-2.3 text encoder: stock Gemma 3 12B, ported in this package.
///
/// Adapts the model + tokenizer pair to ``LTXGemmaEncoding`` so the pipeline
/// drives both generations through one entry point. The behaviour is the
/// pre-existing one, unchanged: pad to `maxLength` on the left with id 0 (Gemma's
/// pad token, *not* eos), run one masked forward, keep all 49 hidden states.
final class Gemma3Encoder: LTXGemmaEncoding {
    let model: Gemma3TextModel
    private let tokenizer: any Tokenizers.Tokenizer

    var numHiddenLayers: Int { model.config.hiddenLayers }

    init(model: Gemma3TextModel, tokenizer: any Tokenizers.Tokenizer) {
        self.model = model
        self.tokenizer = tokenizer
    }

    /// Token ids and mask, left-padded to `maxLength`.
    ///
    /// Unlike Gemma 4, Gemma 3's tokenizer emits BOS from its post-processor, so
    /// nothing is prepended here.
    func tokenize(_ prompt: String, maxLength: Int) -> (inputIds: MLXArray, attentionMask: MLXArray) {
        let encoded = tokenizer.encode(text: prompt)
        if encoded.count > maxLength {
            print("⚠️ Prompt exceeds \(maxLength) tokens (\(encoded.count)); truncating the tail")
        }
        // Keep the FIRST maxLength tokens (HF truncation_side default, and what
        // the Gemma 4 path does) — the previous suffix-keep dropped the head
        // and BOS, silently encoding the wrong half of long prompts.
        var tokens = Array(encoded.prefix(maxLength)).map { Int32($0) }

        let paddingNeeded = maxLength - tokens.count
        let padTokenID: Int32 = 0
        if paddingNeeded > 0 {
            tokens = [Int32](repeating: padTokenID, count: paddingNeeded) + tokens
        }

        let mask = [Float](repeating: 0, count: paddingNeeded)
            + [Float](repeating: 1, count: maxLength - paddingNeeded)

        return (MLXArray(tokens).reshaped([1, maxLength]),
                MLXArray(mask).reshaped([1, maxLength]))
    }

    func encode(prompt: String, maxLength: Int) throws -> (states: [MLXArray], attentionMask: MLXArray) {
        let (inputIds, attentionMask) = tokenize(prompt, maxLength: maxLength)
        MLX.eval(inputIds, attentionMask)

        let (_, allHiddenStates) = model(inputIds, attentionMask: attentionMask, outputHiddenStates: true)
        guard let states = allHiddenStates, states.count == numHiddenLayers + 1 else {
            throw LTXError.textEncodingFailed(
                "Expected \(numHiddenLayers + 1) Gemma hidden states, got "
                + "\(allHiddenStates?.count.description ?? "none")")
        }
        return (states, attentionMask)
    }
}
