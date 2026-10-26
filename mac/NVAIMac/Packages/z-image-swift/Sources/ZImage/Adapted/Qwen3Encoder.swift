// Qwen3 hidden-state encoder — copy-adapted from mlx-swift-lm
// Libraries/MLXLLM/Models/Qwen3.swift (MIT, ml-explore/mlx-swift-lm; itself a port of
// mlx-lm qwen3.py). `Qwen3ModelInner.layers` is fileprivate upstream, so the layer stack
// is vendored here (the Lens `Adapted/` pattern) with the generation surface removed.
//
// Z-Image taps `hidden_states[-2]`: embed + the first (n−1) transformer layers, NO final
// norm, no lm_head. We construct exactly (n−1) layers and the loader drops the unused
// last-layer / norm keys explicitly — leaner than loading a layer that never runs.
// Single forward, no KV cache; causal mask (goldens are right-padded, so valid rows
// never attend to pads and the unpadded sequence is exact).

import Foundation
import MLX
import MLXFast
import MLXNN

public struct Qwen3EncoderConfiguration: Codable, Sendable {
    public var hiddenSize: Int
    public var hiddenLayers: Int
    public var intermediateSize: Int
    public var attentionHeads: Int
    public var rmsNormEps: Float
    public var vocabularySize: Int
    public var kvHeads: Int
    public var ropeTheta: Float
    public var headDim: Int
    public var maxPositionEmbeddings: Int

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case kvHeads = "num_key_value_heads"
        case ropeTheta = "rope_theta"
        case headDim = "head_dim"
        case maxPositionEmbeddings = "max_position_embeddings"
    }

    public static func load(_ url: URL) throws -> Qwen3EncoderConfiguration {
        try JSONDecoder().decode(Qwen3EncoderConfiguration.self, from: Data(contentsOf: url))
    }
}

final class Qwen3Attention: Module {
    let nHeads: Int
    let nKVHeads: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let rope: RoPE

    init(_ args: Qwen3EncoderConfiguration) {
        let dim = args.hiddenSize
        let headDim = args.headDim
        self.nHeads = args.attentionHeads
        self.nKVHeads = args.kvHeads
        self.scale = pow(Float(headDim), -0.5)

        _wq.wrappedValue = Linear(dim, nHeads * headDim, bias: false)
        _wk.wrappedValue = Linear(dim, nKVHeads * headDim, bias: false)
        _wv.wrappedValue = Linear(dim, nKVHeads * headDim, bias: false)
        _wo.wrappedValue = Linear(nHeads * headDim, dim, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)

        // NVAI-open: MLXNN's RoPE instead of mlx-swift-lm's initializeRope (Qwen3-4B has no rope scaling).
        self.rope = RoPE(dimensions: headDim, traditional: false, base: args.ropeTheta)
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode
    ) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))

        var queries = wq(x)
        var keys = wk(x)
        var values = wv(x)

        queries = qNorm(queries.reshaped(B, L, nHeads, -1)).transposed(0, 2, 1, 3)
        keys = kNorm(keys.reshaped(B, L, nKVHeads, -1)).transposed(0, 2, 1, 3)
        values = values.reshaped(B, L, nKVHeads, -1).transposed(0, 2, 1, 3)

        queries = rope(queries)
        keys = rope(keys)

        // NVAI-open: one forward without KV cache, so plain scaled dot-product attention.
        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: scale, mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return wo(output)
    }
}

final class Qwen3MLP: Module {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    init(dimensions: Int, hiddenDimensions: Int) {
        _gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

final class Qwen3TransformerBlock: Module {
    @ModuleInfo(key: "self_attn") var attention: Qwen3Attention
    @ModuleInfo var mlp: Qwen3MLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    init(_ args: Qwen3EncoderConfiguration) {
        _attention.wrappedValue = Qwen3Attention(args)
        _mlp.wrappedValue = Qwen3MLP(
            dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
        _inputLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode
    ) -> MLXArray {
        var r = attention(inputLayerNorm(x), mask: mask)
        let h = x + r
        r = mlp(postAttentionLayerNorm(h))
        return h + r
    }
}

/// Runs embed_tokens + the first (hiddenLayers − 1) blocks; output == PT
/// `hidden_states[-2]`. No final norm, no head.
public final class Qwen3HiddenStateEncoder: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo var layers: [Qwen3TransformerBlock]

    public let configuration: Qwen3EncoderConfiguration

    public init(_ args: Qwen3EncoderConfiguration) {
        self.configuration = args
        _embedTokens.wrappedValue = Embedding(
            embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)
        _layers.wrappedValue = (0..<(args.hiddenLayers - 1)).map { _ in
            Qwen3TransformerBlock(args)
        }
    }

    /// inputs: [B, L] token ids → [B, L, hiddenSize] penultimate hidden states.
    public func callAsFunction(_ inputs: MLXArray) -> MLXArray {
        var h = embedTokens(inputs)
        for layer in layers {
            h = layer(h, mask: .causal)
        }
        return h
    }
}
