// LTXAttention.swift - Attention Mechanisms for LTX-2 Transformer
// Copyright 2025

import Foundation
@preconcurrency import MLX
import MLXFast
import MLXNN

// MARK: - RMS Normalization

/// Root Mean Square Layer Normalization
class RMSNorm: Module, UnaryLayer {
    @ParameterInfo(key: "weight") var weight: MLXArray
    let eps: Float

    init(dims: Int, eps: Float = 1e-6) {
        self.eps = eps
        self._weight.wrappedValue = MLXArray.ones([dims])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        return MLXFast.rmsNorm(x, weight: weight, eps: eps)
    }
}

/// Apply RMS normalization without learnable weight
///
/// Matches Python: `mx.fast.rms_norm(x, mx.ones((x.shape[-1],), dtype=x.dtype), eps)`
/// Weight dtype must match input dtype to avoid float32 promotion.
func rmsNorm(_ x: MLXArray, eps: Float = 1e-6) -> MLXArray {
    let weight = MLXArray.ones([x.dim(-1)]).asType(x.dtype)
    return MLXFast.rmsNorm(x, weight: weight, eps: eps)
}

// MARK: - Scaled Dot-Product Attention

/// Scaled dot-product attention using optimized MLX implementation
///
/// Uses MLXFast.scaledDotProductAttention which is memory-efficient
/// (Flash Attention style) and runs optimized Metal kernels.
func scaledDotProductAttention(
    query: MLXArray,
    key: MLXArray,
    value: MLXArray,
    mask: MLXArray? = nil,
    scale: Float? = nil
) -> MLXArray {
    let s = scale ?? (1.0 / sqrt(Float(query.dim(-1))))
    return MLXFast.scaledDotProductAttention(
        queries: query,
        keys: key,
        values: value,
        scale: s,
        mask: mask
    )
}

// MARK: - Attention Core

/// Attention core computation
private func attentionCore(
    q: MLXArray,
    k: MLXArray,
    v: MLXArray,
    heads: Int,
    dimHead: Int,
    mask: MLXArray? = nil
) -> MLXArray {
    let b = q.dim(0)
    let tQ = q.dim(1)
    let tK = k.dim(1)

    // Reshape for multi-head attention: (B, T, H*D) -> (B, H, T, D)
    let qReshaped = q.reshaped([b, tQ, heads, dimHead]).transposed(0, 2, 1, 3)
    let kReshaped = k.reshaped([b, tK, heads, dimHead]).transposed(0, 2, 1, 3)
    let vReshaped = v.reshaped([b, tK, heads, dimHead]).transposed(0, 2, 1, 3)

    // Handle mask dimensions
    var attnMask = mask
    if let m = mask {
        if m.ndim == 2 {
            attnMask = m.reshaped([1, 1, m.dim(0), m.dim(1)])
        } else if m.ndim == 3 {
            attnMask = MLX.expandedDimensions(m, axis: 1)
        }
        // Ensure mask dtype matches query dtype
        attnMask = attnMask?.asType(qReshaped.dtype)
    }

    // Compute attention using Flash Attention
    let scale = 1.0 / sqrt(Float(dimHead))
    let out = MLXFast.scaledDotProductAttention(
        queries: qReshaped,
        keys: kReshaped,
        values: vReshaped,
        scale: scale,
        mask: attnMask
    )

    // Reshape back: (B, H, T, D) -> (B, T, H*D)
    return out.transposed(0, 2, 1, 3).reshaped([b, tQ, heads * dimHead])
}

// MARK: - Attention Module

/// Multi-head attention with RMSNorm on Q/K and optional RoPE
///
/// This attention module follows the LTX-2 / Diffusers architecture:
/// - Q/K projected to (B, T, innerDim)
/// - RMSNorm applied across all heads on 3D tensor (weight shape: innerDim)
/// - RoPE applied on 3D tensor (applySplitRotaryEmb handles 3D→4D→3D internally)
/// - Then reshape to multi-head format for attention
///
/// Matches Python LTX2Attention with qk_norm="rms_norm_across_heads":
///   self.norm_q = RMSNorm(dim_head * heads, eps=eps)
///   Applied BEFORE head reshape in LTX2AudioVideoAttnProcessor
class LTXAttention: Module {
    let ropeType: LTXRopeType
    let heads: Int
    let dimHead: Int
    let useGatedAttention: Bool

    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    @ModuleInfo(key: "to_q") var toQ: Linear
    @ModuleInfo(key: "to_k") var toK: Linear
    @ModuleInfo(key: "to_v") var toV: Linear
    @ModuleInfo(key: "to_out") var toOut: Linear

    // Gated attention (LTX-2.3): per-head gate = 2 * sigmoid(gate_logits)
    @ModuleInfo(key: "to_gate_logits") var toGateLogits: Linear?

    // Cross-attention KV cache: K and V projected from text context are identical
    // across all denoising steps. Cache them to avoid redundant projections.
    private var _cachedK: MLXArray?
    private var _cachedV: MLXArray?

    init(
        queryDim: Int,
        contextDim: Int? = nil,
        heads: Int = 8,
        dimHead: Int = 64,
        normEps: Float = 1e-6,
        ropeType: LTXRopeType = .split,
        gatedAttention: Bool = false
    ) {
        self.ropeType = ropeType
        self.heads = heads
        self.dimHead = dimHead
        self.useGatedAttention = gatedAttention
        let innerDim = dimHead * heads

        let ctxDim = contextDim ?? queryDim

        // RMSNorm across all heads (matching Python qk_norm="rms_norm_across_heads")
        // Python: self.norm_q = torch.nn.RMSNorm(dim_head * heads, eps=norm_eps)
        // Applied on 3D (B, T, innerDim) BEFORE head reshape
        self._qNorm.wrappedValue = RMSNorm(dims: innerDim, eps: normEps)
        self._kNorm.wrappedValue = RMSNorm(dims: innerDim, eps: normEps)

        // Linear projections
        self._toQ.wrappedValue = Linear(queryDim, innerDim, bias: true)
        self._toK.wrappedValue = Linear(ctxDim, innerDim, bias: true)
        self._toV.wrappedValue = Linear(ctxDim, innerDim, bias: true)

        // Output projection
        self._toOut.wrappedValue = Linear(innerDim, queryDim, bias: true)

        // Gated attention: Linear(queryDim, heads) → per-head scaling
        if gatedAttention {
            self._toGateLogits.wrappedValue = Linear(queryDim, heads, bias: true)
        }
    }

    /// Clear the cross-attention KV cache (call between generations)
    func clearKVCache() {
        _cachedK = nil
        _cachedV = nil
    }

    func callAsFunction(
        _ x: MLXArray,
        context: MLXArray? = nil,
        mask: MLXArray? = nil,
        pe: (cos: MLXArray, sin: MLXArray)? = nil,
        kPe: (cos: MLXArray, sin: MLXArray)? = nil,
        useKVCache: Bool = false
    ) -> MLXArray {
        let b = x.dim(0)
        let tQ = x.dim(1)

        // Compute gate logits from original input (before Q/K/V projection)
        // gate_logits: (B, T, heads)
        var gateLogits: MLXArray? = nil
        if let gateProj = toGateLogits {
            gateLogits = gateProj(x)
        }

        // Project Q from hidden states
        var q = toQ(x)
        q = qNorm(q)

        // Project K, V from context (or self), with optional caching.
        // For cross-attention, context is text embeddings which don't change
        // between denoising steps. Cache the normalized K and V to avoid
        // redundant projections (48 blocks × N steps → 48 projections instead of 48×N).
        var k: MLXArray
        let v: MLXArray
        if useKVCache, let cachedK = _cachedK, let cachedV = _cachedV {
            k = cachedK
            v = cachedV
        } else {
            let ctx = context ?? x
            k = kNorm(toK(ctx))
            v = toV(ctx)
            if useKVCache {
                _cachedK = k
                _cachedV = v
            }
        }
        let tK = k.dim(1)

        // Apply RoPE on 3D tensor BEFORE head reshape
        // applySplitRotaryEmb handles 3D input when cos is 4D:
        // internally reshapes (B,T,H*D) → (B,H,T,D), applies RoPE, reshapes back
        if let posEmb = pe {
            q = applyRotaryEmb(q, freqsCis: posEmb, ropeType: ropeType)
            let keyPosEmb = kPe ?? posEmb
            k = applyRotaryEmb(k, freqsCis: keyPosEmb, ropeType: ropeType)
        }

        // NOW reshape into multi-head: (B, T, H*D) → (B, H, T, D)
        let qR = q.reshaped([b, tQ, heads, dimHead]).transposed(0, 2, 1, 3)
        let kR = k.reshaped([b, tK, heads, dimHead]).transposed(0, 2, 1, 3)
        let vR = v.reshaped([b, tK, heads, dimHead]).transposed(0, 2, 1, 3)

        // Handle mask dimensions
        var attnMask = mask
        if let m = mask {
            if m.ndim == 2 {
                attnMask = m.reshaped([1, 1, m.dim(0), m.dim(1)])
            } else if m.ndim == 3 {
                attnMask = MLX.expandedDimensions(m, axis: 1)
            }
            attnMask = attnMask?.asType(qR.dtype)
        }

        // Scaled dot-product attention (Flash Attention)
        let scale = 1.0 / sqrt(Float(dimHead))
        var out = MLXFast.scaledDotProductAttention(
            queries: qR, keys: kR, values: vR, scale: scale, mask: attnMask
        )

        // Apply gated attention (LTX-2.3): per-head gate = 2 * sigmoid(gate_logits)
        // gate_logits: (B, T, H) → (B, H, T, 1) to broadcast with (B, H, T, D)
        if let gl = gateLogits {
            let gate = 2.0 * sigmoid(gl)  // (B, T, H), range [0, 2]
            let gateR = gate.transposed(0, 2, 1).expandedDimensions(axis: -1)  // (B, H, T, 1)
            out = out * gateR
        }

        // Reshape back: (B, H, T, D) → (B, T, H*D)
        let combined = out.transposed(0, 2, 1, 3).reshaped([b, tQ, heads * dimHead])

        // Output projection
        return toOut(combined)
    }
}

// MARK: - Self-Attention

/// Self-attention layer (convenience wrapper)
class SelfAttention: Module {
    @ModuleInfo var attn: LTXAttention

    init(
        dim: Int,
        heads: Int = 8,
        dimHead: Int = 64,
        normEps: Float = 1e-6,
        ropeType: LTXRopeType = .split
    ) {
        self._attn.wrappedValue = LTXAttention(
            queryDim: dim,
            contextDim: dim,
            heads: heads,
            dimHead: dimHead,
            normEps: normEps,
            ropeType: ropeType
        )
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXArray? = nil,
        pe: (cos: MLXArray, sin: MLXArray)? = nil
    ) -> MLXArray {
        return attn(x, context: nil, mask: mask, pe: pe)
    }
}

// MARK: - Cross-Attention

/// Cross-attention layer (convenience wrapper)
class CrossAttention: Module {
    @ModuleInfo var attn: LTXAttention

    init(
        queryDim: Int,
        contextDim: Int,
        heads: Int = 8,
        dimHead: Int = 64,
        normEps: Float = 1e-6
    ) {
        // Cross-attention typically doesn't use RoPE
        self._attn.wrappedValue = LTXAttention(
            queryDim: queryDim,
            contextDim: contextDim,
            heads: heads,
            dimHead: dimHead,
            normEps: normEps,
            ropeType: .split
        )
    }

    func callAsFunction(
        _ x: MLXArray,
        context: MLXArray,
        mask: MLXArray? = nil,
        useKVCache: Bool = false
    ) -> MLXArray {
        return attn(x, context: context, mask: mask, pe: nil, useKVCache: useKVCache)
    }

    func clearKVCache() {
        attn.clearKVCache()
    }
}
