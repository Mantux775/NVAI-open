// The LTX-Video transformer (Lightricks "Transformer3DModel", 0.9.x 2B): 28 blocks of width 2048 (32 heads of 64)
// on single-voxel tokens of the 128-channel latent. Each block: RMS-normed self-attention with 3-axis rotary
// positions, unnormalized cross-attention to the projected T5 features, RMS-normed GELU feed-forward; shift, scale and
// gate of self-attention and feed-forward come from the timestep (adaLN-single, PixArt-α).

import Foundation
import MLX
import MLXFast
import MLXNN

public struct LTXTransformerConfiguration: Sendable {
    public var inChannels = 128
    public var heads = 32
    public var headDim = 64
    public var layers = 28
    public var captionChannels = 4096
    public var ropeTheta: Float = 10000
    public var maxPositions: [Float] = [20, 2048, 2048]
    public var timestepScale: Float = 1000
    /// Latent voxel → pixel: frames × 8, height and width × 32.
    public var vaeScale: (t: Int, h: Int, w: Int) = (8, 32, 32)
    public var dim: Int { heads * headDim }
    public init() {}
}

/// Sinusoidal timestep features as in PixArt / diffusers (`flip_sin_to_cos`, no frequency shift): [N, dims].
func timestepFeatures(_ t: [Float], dims: Int = 256, maxPeriod: Float = 10000) -> MLXArray {
    let half = dims / 2
    var out = [Float](repeating: 0, count: t.count * dims)
    for (row, value) in t.enumerated() {
        for i in 0 ..< half {
            let freq = exp(-log(maxPeriod) * Float(i) / Float(half))
            let arg = value * freq
            out[row * dims + i] = cos(arg)
            out[row * dims + half + i] = sin(arg)
        }
    }
    return MLXArray(out, [t.count, dims])
}

/// `timestep_embedder`: linear → SiLU → linear.
final class TimestepEmbedder: Module {
    @ModuleInfo(key: "linear_1") var linear1: Linear
    @ModuleInfo(key: "linear_2") var linear2: Linear

    init(_ inDims: Int, _ dims: Int) {
        _linear1.wrappedValue = Linear(inDims, dims)
        _linear2.wrappedValue = Linear(dims, dims)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { linear2(silu(linear1(x))) }
}

/// PixArt's `PixArtAlphaCombinedTimestepSizeEmbeddings` without the size conditions: only `timestep_embedder`.
final class CombinedTimestepEmbedder: Module {
    @ModuleInfo(key: "timestep_embedder") var timestepEmbedder: TimestepEmbedder

    init(_ dims: Int) {
        _timestepEmbedder.wrappedValue = TimestepEmbedder(256, dims)
        super.init()
    }

    /// Embeds an already scaled timestep, [1, dims] in `dtype`.
    func callAsFunction(_ scaledTimestep: Float, dtype: DType) -> MLXArray {
        timestepEmbedder(timestepFeatures([scaledTimestep]).asType(dtype))
    }
}

final class AdaLNSingle: Module {
    @ModuleInfo var emb: CombinedTimestepEmbedder
    @ModuleInfo var linear: Linear

    init(_ dims: Int, coefficients: Int = 6) {
        _emb.wrappedValue = CombinedTimestepEmbedder(dims)
        _linear.wrappedValue = Linear(dims, coefficients * dims)
        super.init()
    }
}

final class CaptionProjection: Module {
    @ModuleInfo(key: "linear_1") var linear1: Linear
    @ModuleInfo(key: "linear_2") var linear2: Linear

    init(_ inDims: Int, _ dims: Int) {
        _linear1.wrappedValue = Linear(inDims, dims)
        _linear2.wrappedValue = Linear(dims, dims)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { linear2(geluApproximate(linear1(x))) }
}

/// Rotary tables per token pair: cos and sin, [1, T, dim / 2].
public struct LTXRope {
    public let cos: MLXArray
    public let sin: MLXArray

    /// Interleaved pairs; x [B, T, dim]. Computed in float32, returned in x's type.
    func apply(_ x: MLXArray) -> MLXArray {
        let shape = x.shape
        let parts = split(x.asType(.float32).reshaped(shape[0], shape[1], -1, 2), parts: 2, axis: -1)
        let x0 = parts[0].squeezed(axis: -1), x1 = parts[1].squeezed(axis: -1)
        let out = stacked([x0 * cos - x1 * sin, x0 * sin + x1 * cos], axis: -1)
        return out.reshaped(shape).asType(x.dtype)
    }
}

final class LTXAttention: Module {
    @ModuleInfo(key: "to_q") var toQ: Linear
    @ModuleInfo(key: "to_k") var toK: Linear
    @ModuleInfo(key: "to_v") var toV: Linear
    @ModuleInfo(key: "to_out") var toOut: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm
    let heads: Int
    let scale: Float

    init(_ c: LTXTransformerConfiguration) {
        heads = c.heads
        scale = 1 / Float(c.headDim).squareRoot()
        _toQ.wrappedValue = Linear(c.dim, c.dim)
        _toK.wrappedValue = Linear(c.dim, c.dim)
        _toV.wrappedValue = Linear(c.dim, c.dim)
        _toOut.wrappedValue = Linear(c.dim, c.dim)
        _qNorm.wrappedValue = RMSNorm(dimensions: c.dim, eps: 1e-5)
        _kNorm.wrappedValue = RMSNorm(dimensions: c.dim, eps: 1e-5)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, context: MLXArray? = nil, rope: LTXRope? = nil) -> MLXArray {
        let source = context ?? x
        var q = qNorm(toQ(x))
        var k = kNorm(toK(source))
        let v = toV(source)
        if let rope {
            q = rope.apply(q)
            k = rope.apply(k)
        }
        let b = x.dim(0)
        let split = { (a: MLXArray) in a.reshaped(b, a.dim(1), self.heads, -1).transposed(0, 2, 1, 3) }
        let out = MLXFast.scaledDotProductAttention(
            queries: split(q), keys: split(k), values: split(v), scale: scale, mask: nil)
        return toOut(out.transposed(0, 2, 1, 3).reshaped(b, x.dim(1), -1))
    }
}

final class LTXFeedForward: Module {
    @ModuleInfo(key: "proj_in") var projIn: Linear
    @ModuleInfo(key: "proj_out") var projOut: Linear

    init(_ dims: Int, mult: Int = 4) {
        _projIn.wrappedValue = Linear(dims, dims * mult)
        _projOut.wrappedValue = Linear(dims * mult, dims)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { projOut(geluApproximate(projIn(x))) }
}

/// RMS norm without weights (eps 1e-6), as in front of self-attention and feed-forward.
func plainRMSNorm(_ x: MLXArray, eps: Float = 1e-6) -> MLXArray {
    let ones = MLXArray.ones([x.dim(-1)], dtype: x.dtype)
    return MLXFast.rmsNorm(x, weight: ones, eps: eps)
}

final class LTXBlock: Module {
    @ModuleInfo var attn1: LTXAttention
    @ModuleInfo var attn2: LTXAttention
    @ModuleInfo var ff: LTXFeedForward
    @ParameterInfo(key: "scale_shift_table") var scaleShiftTable: MLXArray

    init(_ c: LTXTransformerConfiguration) {
        _attn1.wrappedValue = LTXAttention(c)
        _attn2.wrappedValue = LTXAttention(c)
        _ff.wrappedValue = LTXFeedForward(c.dim)
        _scaleShiftTable.wrappedValue = MLXArray.zeros([6, c.dim])
        super.init()
    }

    /// `ada`: the timestep modulation, [B, 1, 6, dim]. The residual stream `x` may be float32 while the weights are
    /// bf16: the layers then get bf16 inputs and their outputs are added in float32.
    func callAsFunction(_ x: MLXArray, context: MLXArray, ada: MLXArray, rope: LTXRope, compute: DType) -> MLXArray {
        let m = split(scaleShiftTable.asType(x.dtype).reshaped(1, 1, 6, -1) + ada.asType(x.dtype), parts: 6, axis: 2)
            .map { $0.squeezed(axis: 2) }                                    // each [B, 1, dim]
        let shiftMSA = m[0], scaleMSA = m[1], gateMSA = m[2], shiftMLP = m[3], scaleMLP = m[4], gateMLP = m[5]
        var h = x
        let a = attn1((plainRMSNorm(h) * (1 + scaleMSA) + shiftMSA).asType(compute), rope: rope)
        h = h + a.asType(x.dtype) * gateMSA
        h = h + attn2(h.asType(compute), context: context).asType(x.dtype)
        let f = ff((plainRMSNorm(h) * (1 + scaleMLP) + shiftMLP).asType(compute))
        h = h + f.asType(x.dtype) * gateMLP
        return h
    }
}

public final class LTXTransformer: Module {
    @ModuleInfo(key: "patchify_proj") var patchifyProj: Linear
    @ModuleInfo(key: "adaln_single") var adaln: AdaLNSingle
    @ModuleInfo(key: "caption_projection") var captionProjection: CaptionProjection
    @ModuleInfo(key: "transformer_blocks") var blocks: [LTXBlock]
    @ParameterInfo(key: "scale_shift_table") var scaleShiftTable: MLXArray
    @ModuleInfo(key: "proj_out") var projOut: Linear
    public let config: LTXTransformerConfiguration
    /// Residual stream in float32 (layers still compute in the weights' type). Off: bf16 throughout, as ComfyUI runs
    /// it; on random latents both landed about as far from a float32 reference (relL2 0.2 and 0.4, ComfyUI bf16 0.18).
    public var residualFloat32 = false

    public init(_ c: LTXTransformerConfiguration = LTXTransformerConfiguration()) {
        config = c
        _patchifyProj.wrappedValue = Linear(c.inChannels, c.dim)
        _adaln.wrappedValue = AdaLNSingle(c.dim)
        _captionProjection.wrappedValue = CaptionProjection(c.captionChannels, c.dim)
        _blocks.wrappedValue = (0 ..< c.layers).map { _ in LTXBlock(c) }
        _scaleShiftTable.wrappedValue = MLXArray.zeros([2, c.dim])
        _projOut.wrappedValue = Linear(c.dim, c.inChannels)
        super.init()
    }

    /// Rotary tables for a latent of `frames` × `height` × `width` voxels, tokens in (f, h, w) order. The position of
    /// a voxel is its pixel corner (frame × 8 / frameRate seconds, y × 32, x × 32) over `maxPositions`, mapped to
    /// [−1, 1]; 341 frequencies θ^(0…1)·π/2 per axis, interleaved as (f0 t, f0 y, f0 x, f1 t, …) after one unrotated pair.
    public func rope(frames: Int, height: Int, width: Int, frameRate: Float) -> LTXRope {
        let pairs = config.dim / 2
        let perAxis = config.dim / 6
        let pad = pairs - 3 * perAxis
        let freqs = (0 ..< perAxis).map { i -> Float in
            let e = perAxis > 1 ? Float(i) / Float(perAxis - 1) : 0
            return pow(config.ropeTheta, e) * Float.pi / 2
        }
        let tokens = frames * height * width
        var cosv = [Float](repeating: 1, count: tokens * pairs)
        var sinv = [Float](repeating: 0, count: tokens * pairs)
        var token = 0
        for f in 0 ..< frames {
            let t = Float(f * config.vaeScale.t) / frameRate / config.maxPositions[0] * 2 - 1
            for y in 0 ..< height {
                let py = Float(y * config.vaeScale.h) / config.maxPositions[1] * 2 - 1
                for x in 0 ..< width {
                    let px = Float(x * config.vaeScale.w) / config.maxPositions[2] * 2 - 1
                    let base = token * pairs + pad
                    for i in 0 ..< perAxis {
                        let o = base + i * 3
                        let a = freqs[i] * t, b = freqs[i] * py, c = freqs[i] * px
                        cosv[o] = cos(a); sinv[o] = sin(a)
                        cosv[o + 1] = cos(b); sinv[o + 1] = sin(b)
                        cosv[o + 2] = cos(c); sinv[o + 2] = sin(c)
                    }
                    token += 1
                }
            }
        }
        return LTXRope(cos: MLXArray(cosv, [1, tokens, pairs]), sin: MLXArray(sinv, [1, tokens, pairs]))
    }

    /// Velocity for latent tokens [B, N, 128] at noise level `sigma` (0…1), with T5 features [B, L, 4096].
    /// `conditionedTokens` > 0: the first tokens (the start image in the first latent frame) are clean and get
    /// timestep 0, the others `sigma` – a timestep per token, as ComfyUI's LTXVImgToVideo with strength 1 does it.
    public func callAsFunction(_ tokens: MLXArray, sigma: Float, context: MLXArray, rope: LTXRope,
                               conditionedTokens: Int = 0) -> MLXArray {
        let dtype = patchifyProj.weight.dtype == .uint32 ? DType.bfloat16 : patchifyProj.weight.dtype
        var x = patchifyProj(tokens.asType(dtype))
        let b = x.dim(0), n = x.dim(1)
        var embedded = adaln.emb(sigma * config.timestepScale, dtype: dtype)                 // [1, dim]
        var ada = adaln.linear(silu(embedded)).reshaped(b, 1, 6, config.dim)                 // [B, 1, 6, dim]
        let k = min(max(conditionedTokens, 0), n)
        if k > 0 {
            // Only two timesteps occur: modulation per token by concatenating both.
            let clean = adaln.emb(0, dtype: dtype)
            let cleanAda = adaln.linear(silu(clean)).reshaped(b, 1, 6, config.dim)
            ada = concatenated([broadcast(cleanAda, to: [b, k, 6, config.dim]),
                                broadcast(ada, to: [b, n - k, 6, config.dim])], axis: 1)    // [B, N, 6, dim]
            embedded = concatenated([broadcast(clean.reshaped(1, 1, -1), to: [b, k, config.dim]),
                                     broadcast(embedded.reshaped(1, 1, -1), to: [b, n - k, config.dim])], axis: 1)
        }
        let ctx = captionProjection(context.asType(dtype))
        if residualFloat32 { x = x.asType(.float32) }
        for block in blocks { x = block(x, context: ctx, ada: ada, rope: rope, compute: dtype) }
        let table = scaleShiftTable.asType(dtype)                                              // [2, dim]
        let shift = (table[0] + embedded).asType(x.dtype)                                      // [dim] or [B, N, dim]
        let scale = (table[1] + embedded).asType(x.dtype)
        x = MLXFast.layerNorm(x, weight: nil, bias: nil, eps: 1e-6) * (1 + scale) + shift
        return projOut(x.asType(dtype))
    }
}
