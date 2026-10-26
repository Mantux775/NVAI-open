// Z-Image text conditioning — mirrors src/zimage/pipeline.py lines 108–138.
// Qwen3 thinking-mode chat template (rendered directly; golden-gated against the PT
// tokenizer's apply_chat_template output), tokenize, run the hidden-state encoder,
// return per-prompt variable-length features (the reference masked-gather).
//
// The reference pads to max_length=512 then gathers valid rows; tokens are right-padded
// and attention is causal, so running the UNPADDED sequence is exact (verified in P4).

import Foundation
import MLX
import Tokenizers

public final class ZImageTextEncoder {

    public let encoder: Qwen3HiddenStateEncoder
    public let tokenizer: Tokenizer
    public let maxSequenceLength: Int

    public init(
        encoder: Qwen3HiddenStateEncoder,
        tokenizer: Tokenizer,
        maxSequenceLength: Int = 512
    ) {
        self.encoder = encoder
        self.tokenizer = tokenizer
        self.maxSequenceLength = maxSequenceLength
    }

    /// Qwen3 chat template for a single user turn, add_generation_prompt=True,
    /// enable_thinking=True (no <think> block is inserted in thinking mode).
    /// Golden: tests/goldens/zimage_encoder_meta.json.
    public static func formatPrompt(_ prompt: String) -> String {
        "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"
    }

    public func tokenize(_ prompt: String) -> [Int] {
        var ids = tokenizer.encode(text: Self.formatPrompt(prompt))
        if ids.count > maxSequenceLength {
            ids = Array(ids.prefix(maxSequenceLength))
        }
        return ids
    }

    /// prompt → [len, hiddenSize] features (== PT hidden_states[-2] masked-gathered).
    public func encode(_ prompt: String) -> MLXArray {
        let ids = tokenize(prompt)
        let hidden = encoder(MLXArray(ids.map(Int32.init), [1, ids.count]))
        return hidden[0]
    }
}
