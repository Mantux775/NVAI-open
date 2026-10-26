// T5 v1.1 XXL encoder, the text encoder of LTX-Video (PixArt's T5, the same weights as FLUX.1's text_encoder_2).
// 24 layers, d_model 4096, 64 heads of 64, gated-GELU feed-forward 10240. Attention without the 1/sqrt(d) scaling
// and with a bucketed relative position bias that the first layer computes and every layer adds.

import Foundation
import MLX
import MLXFast
import MLXNN
import Tokenizers

public struct T5Configuration: Sendable {
    public var dModel = 4096
    public var heads = 64
    public var headDim = 64
    public var ffDim = 10240
    public var layers = 24
    public var vocabulary = 32128
    public var buckets = 32
    public var maxDistance = 128
    public var eps: Float = 1e-6
    public init() {}
}

/// T5's RMS norm: no mean subtraction, no bias.
final class T5LayerNorm: Module {
    let weight: MLXArray
    let eps: Float

    init(_ dims: Int, eps: Float) {
        weight = MLXArray.ones([dims])
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: weight.asType(x.dtype), eps: eps)
    }
}

final class T5Attention: Module {
    @ModuleInfo var q: Linear
    @ModuleInfo var k: Linear
    @ModuleInfo var v: Linear
    @ModuleInfo var o: Linear
    let heads: Int

    init(_ c: T5Configuration) {
        heads = c.heads
        _q.wrappedValue = Linear(c.dModel, c.heads * c.headDim, bias: false)
        _k.wrappedValue = Linear(c.dModel, c.heads * c.headDim, bias: false)
        _v.wrappedValue = Linear(c.dModel, c.heads * c.headDim, bias: false)
        _o.wrappedValue = Linear(c.heads * c.headDim, c.dModel, bias: false)
        super.init()
    }

    /// `bias`: [1, heads, T, T], added to the scores.
    func callAsFunction(_ x: MLXArray, bias: MLXArray) -> MLXArray {
        let b = x.dim(0), t = x.dim(1)
        let split = { (a: MLXArray) in a.reshaped(b, t, self.heads, -1).transposed(0, 2, 1, 3) }
        let out = MLXFast.scaledDotProductAttention(
            queries: split(q(x)), keys: split(k(x)), values: split(v(x)), scale: 1, mask: bias)
        return o(out.transposed(0, 2, 1, 3).reshaped(b, t, -1))
    }
}

final class T5SelfAttentionLayer: Module {
    @ModuleInfo(key: "SelfAttention") var selfAttention: T5Attention
    @ModuleInfo(key: "layer_norm") var layerNorm: T5LayerNorm

    init(_ c: T5Configuration) {
        _selfAttention.wrappedValue = T5Attention(c)
        _layerNorm.wrappedValue = T5LayerNorm(c.dModel, eps: c.eps)
        super.init()
    }
}

final class T5GatedFeedForward: Module {
    @ModuleInfo(key: "wi_0") var wi0: Linear
    @ModuleInfo(key: "wi_1") var wi1: Linear
    @ModuleInfo var wo: Linear

    init(_ c: T5Configuration) {
        _wi0.wrappedValue = Linear(c.dModel, c.ffDim, bias: false)
        _wi1.wrappedValue = Linear(c.dModel, c.ffDim, bias: false)
        _wo.wrappedValue = Linear(c.ffDim, c.dModel, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        wo(geluApproximate(wi0(x)) * wi1(x))
    }
}

final class T5FeedForwardLayer: Module {
    @ModuleInfo(key: "DenseReluDense") var dense: T5GatedFeedForward
    @ModuleInfo(key: "layer_norm") var layerNorm: T5LayerNorm

    init(_ c: T5Configuration) {
        _dense.wrappedValue = T5GatedFeedForward(c)
        _layerNorm.wrappedValue = T5LayerNorm(c.dModel, eps: c.eps)
        super.init()
    }
}

final class T5Block: Module {
    @ModuleInfo var attention: T5SelfAttentionLayer
    @ModuleInfo var ff: T5FeedForwardLayer

    init(_ c: T5Configuration) {
        _attention.wrappedValue = T5SelfAttentionLayer(c)
        _ff.wrappedValue = T5FeedForwardLayer(c)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, bias: MLXArray) -> MLXArray {
        var h = x + attention.selfAttention(attention.layerNorm(x), bias: bias)
        h = h + ff.dense(ff.layerNorm(h))
        return h
    }
}

/// Module names follow the mflux checkpoints (`t5_blocks.N.attention.SelfAttention.q`, …). The relative position
/// table is one table for all layers (HF: only block 0 has it).
public final class T5Encoder: Module {
    @ModuleInfo var shared: Embedding
    @ModuleInfo(key: "t5_blocks") var blocks: [T5Block]
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: T5LayerNorm
    @ModuleInfo(key: "relative_attention_bias") var relativeAttentionBias: Embedding
    public let config: T5Configuration

    public init(_ c: T5Configuration = T5Configuration()) {
        config = c
        _shared.wrappedValue = Embedding(embeddingCount: c.vocabulary, dimensions: c.dModel)
        _blocks.wrappedValue = (0 ..< c.layers).map { _ in T5Block(c) }
        _finalLayerNorm.wrappedValue = T5LayerNorm(c.dModel, eps: c.eps)
        _relativeAttentionBias.wrappedValue = Embedding(embeddingCount: c.buckets, dimensions: c.heads)
        super.init()
    }

    /// Bucket of `memory − query` (bidirectional): half the buckets for each direction, the first half of those exact,
    /// the rest logarithmic up to `maxDistance`. Float32 arithmetic like the reference, so boundaries land alike.
    static func bucket(_ relative: Int, buckets: Int, maxDistance: Int) -> Int {
        let half = buckets / 2
        var result = relative > 0 ? half : 0
        let n = abs(relative)
        let maxExact = half / 2
        if n < maxExact { return result + n }
        let ratio = Float(log(Double(Float(n) / Float(maxExact)))) / Float(log(Double(maxDistance) / Double(maxExact)))
        result += min(maxExact + Int(ratio * Float(half - maxExact)), half - 1)
        return result
    }

    /// [1, heads, T, T] position bias for `t` tokens.
    func positionBias(_ t: Int, dtype: DType) -> MLXArray {
        var ids = [Int32](repeating: 0, count: t * t)
        for i in 0 ..< t {
            for j in 0 ..< t {
                ids[i * t + j] = Int32(Self.bucket(j - i, buckets: config.buckets, maxDistance: config.maxDistance))
            }
        }
        let table = relativeAttentionBias(MLXArray(ids, [t, t]))  // [T, T, heads]
        return table.transposed(2, 0, 1)[.newAxis].asType(dtype)
    }

    /// Last hidden state (after the final norm) for token ids [1, T], in `dtype`.
    public func callAsFunction(_ ids: MLXArray, dtype: DType = .float32) -> MLXArray {
        var x = shared(ids).asType(dtype)
        let bias = positionBias(ids.dim(1), dtype: dtype)
        for block in blocks { x = block(x, bias: bias) }
        return finalLayerNorm(x)
    }
}

/// Prompt → T5 features. LTX-Video masks padding in the T5 attention and in the cross-attention, so the unpadded
/// prompt (with the closing `</s>`) gives the same features for the real tokens; the reference truncates at 256.
public struct T5TextEncoder {
    public let encoder: T5Encoder
    public let tokenizer: Tokenizer
    public var maxTokens = 256

    public init(encoder: T5Encoder, tokenizer: Tokenizer) {
        self.encoder = encoder
        self.tokenizer = tokenizer
    }

    public func tokens(_ prompt: String) -> [Int] {
        var ids = tokenizer.encode(text: prompt)
        if ids.last != 1 { ids.append(1) }  // </s>
        if ids.count > maxTokens { ids = Array(ids.prefix(maxTokens - 1)) + [1] }
        return ids
    }

    /// [1, T, 4096] in float32.
    public func encode(_ prompt: String) -> MLXArray {
        let ids = tokens(prompt)
        let out = encoder(MLXArray(ids.map(Int32.init), [1, ids.count]))
        eval(out)
        return out
    }
}
