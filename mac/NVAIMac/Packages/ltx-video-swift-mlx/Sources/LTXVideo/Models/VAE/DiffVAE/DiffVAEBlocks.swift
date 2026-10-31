// DiffVAEBlocks.swift - Transformer blocks of the diffusion video decoder
// Copyright 2026

import Foundation
@preconcurrency import MLX
import MLXNN

// MARK: - Absolute 3D RoPE

/// Absolute RoPE applied per axis over a `(T, H, W)` volume.
///
/// `head_dim` is split across the three axes — a quarter (rounded to even) for
/// time, the rest halved between height and width — and each chunk is rotated by
/// its own coordinate. Absolute, not relative: positions come from the volume,
/// not from query-key offsets.
struct AbsoluteRoPE3D {
    let split: (t: Int, h: Int, w: Int)
    let base: Float

    init(headDim: Int, base: Float = 10000.0) {
        var dt = (headDim / 4) / 2 * 2
        var dhw = (headDim - dt) / 2
        if dhw % 2 != 0 {
            dt -= 2
            dhw = (headDim - dt) / 2
        }
        self.split = (dt, dhw, dhw)
        self.base = base
    }

    /// `1 / base^(i/dim)` for even `i` — the standard inverse frequencies.
    static func inverseFrequencies(dim: Int, base: Float) -> MLXArray {
        let exponents = stride(from: 0, to: dim, by: 2).map { Float($0) / Float(dim) }
        return MLXArray(exponents.map { 1.0 / powf(base, $0) })
    }

    /// Rotate one axis chunk `[B, heads, T, H, W, D]` by its coordinate.
    /// `axis` is the volume axis (0 = T, 1 = H, 2 = W) in that layout.
    private func rotate(_ chunk: MLXArray, axis: Int, length: Int, dim: Int) -> MLXArray {
        let inv = Self.inverseFrequencies(dim: dim, base: base)
        let pos = MLXArray(0 ..< length).asType(.float32)
        // Angles broadcast along the rotated axis only.
        var shape = [1, 1, 1, 1, 1, inv.dim(0)]
        shape[2 + axis] = length
        let ang = (pos[0..., .newAxis] * inv[.newAxis, 0...]).reshaped(shape)
        let c = MLX.cos(ang), s = MLX.sin(ang)

        let pairs = chunk.reshaped(Array(chunk.shape.dropLast()) + [chunk.dim(-1) / 2, 2])
        let xe = pairs[.ellipsis, 0].asType(.float32)
        let xo = pairs[.ellipsis, 1].asType(.float32)
        let re = xe * c - xo * s
        let ro = xe * s + xo * c
        return MLX.stacked([re, ro], axis: -1)
            .reshaped(chunk.shape).asType(chunk.dtype)
    }

    /// Apply the three axis rotations to `[B, heads, T, H, W, headDim]`.
    func callAsFunction(_ x: MLXArray, dims: (Int, Int, Int)) -> MLXArray {
        var offset = 0
        var parts: [MLXArray] = []
        for (axis, (dim, length)) in [
            (split.t, dims.0), (split.h, dims.1), (split.w, dims.2),
        ].enumerated() {
            let chunk = x[.ellipsis, offset ..< (offset + dim)]
            parts.append(rotate(chunk, axis: axis, length: length, dim: dim))
            offset += dim
        }
        if offset < x.dim(-1) {   // untouched tail, if head_dim isn't fully split
            parts.append(x[.ellipsis, offset...])
        }
        return MLX.concatenated(parts, axis: -1)
    }
}

// MARK: - Attention

/// Neighborhood attention with absolute RoPE — the shared attention of every
/// decoder block.
public class DiffVAEAttention: Module {
    let dim: Int
    let heads: Int
    let headDim: Int
    let kernel: (Int, Int, Int)
    let scale: Float
    let rope: AbsoluteRoPE3D

    @ModuleInfo(key: "qkv") var qkv: Linear
    @ModuleInfo(key: "proj") var proj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    public init(dim: Int, kernel: (Int, Int, Int), headDim: Int = 64) {
        self.dim = dim
        self.heads = dim / headDim
        self.headDim = headDim
        self.kernel = kernel
        self.scale = powf(Float(headDim), -0.5)
        self.rope = AbsoluteRoPE3D(headDim: headDim)
        self._qkv.wrappedValue = Linear(dim, dim * 3, bias: true)
        self._proj.wrappedValue = Linear(dim, dim, bias: true)
        self._qNorm.wrappedValue = RMSNorm(dims: headDim, eps: 1e-6)
        self._kNorm.wrappedValue = RMSNorm(dims: headDim, eps: 1e-6)
        super.init()
    }

    /// `x`: `[B, T, H, W, C]` channels-last, as the whole decoder is.
    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (B, T, H, W) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        let n = T * H * W

        let fused = qkv(x).reshaped([B, n, 3, heads, headDim])
        // → [B, heads, T, H, W, headDim] per projection
        func part(_ i: Int) -> MLXArray {
            fused[0..., 0..., i, 0..., 0...]
                .transposed(0, 2, 1, 3)
                .reshaped([B, heads, T, H, W, headDim])
        }
        var q = qNorm(part(0))
        var k = kNorm(part(1))
        let v = part(2)

        q = rope(q, dims: (T, H, W))
        k = rope(k, dims: (T, H, W))

        let out = NeighborhoodAttention3D.callAsFunction(
            q: q, k: k, v: v, dims: (T, H, W), kernels: kernel, causalTime: false, scale: scale)
        return proj(out.reshaped([B, heads, n, headDim])
            .transposed(0, 2, 1, 3)
            .reshaped([B, T, H, W, dim]))
    }
}

// MARK: - SwiGLU

/// The decoder's feed-forward: `w_down(silu(w_gate(x)) * w_up(x))`, bias-free.
public class DiffVAESwiGLU: Module {
    @ModuleInfo(key: "w_gate") var wGate: Linear
    @ModuleInfo(key: "w_up") var wUp: Linear
    @ModuleInfo(key: "w_down") var wDown: Linear

    public init(dim: Int, hidden: Int) {
        self._wGate.wrappedValue = Linear(dim, hidden, bias: false)
        self._wUp.wrappedValue = Linear(dim, hidden, bias: false)
        self._wDown.wrappedValue = Linear(hidden, dim, bias: false)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        wDown(MLXNN.silu(wGate(x)) * wUp(x))
    }

    /// Hidden width: `dim * ratio` rounded up to a multiple of 16, as upstream.
    public static func hiddenWidth(dim: Int, ratio: Float = 4.0) -> Int {
        (Int(Float(dim) * ratio) + 15) / 16 * 16
    }
}

// MARK: - Deterministic stage block

/// Pre-norm block of the deterministic stages: `x + NA(norm(x))`, then
/// `x + SwiGLU(norm(x))`. No conditioning — these stages only upsample the
/// latent into the context volume.
public class DiffVAENABlock: Module {
    @ModuleInfo(key: "norm1") var norm1: RMSNorm
    @ModuleInfo(key: "attn") var attn: DiffVAEAttention
    @ModuleInfo(key: "norm2") var norm2: RMSNorm
    @ModuleInfo(key: "mlp") var mlp: DiffVAESwiGLU

    public init(dim: Int, kernel: (Int, Int, Int), headDim: Int = 64) {
        self._norm1.wrappedValue = RMSNorm(dims: dim, eps: 1e-6)
        self._attn.wrappedValue = DiffVAEAttention(dim: dim, kernel: kernel, headDim: headDim)
        self._norm2.wrappedValue = RMSNorm(dims: dim, eps: 1e-6)
        self._mlp.wrappedValue = DiffVAESwiGLU(
            dim: dim, hidden: DiffVAESwiGLU.hiddenWidth(dim: dim))
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x + attn(norm1(x))
        h = h + mlp(norm2(h))
        return h
    }
}

// MARK: - Diffusion stage block

/// Block of the diffusion stage: the context volume is projected in as a
/// residual, then attention and MLP run modulated by AdaLN-Zero.
///
/// The seven AdaLN chunks are `scale_msa, shift_msa, gate_msa, scale_mlp,
/// shift_mlp, gate_mlp, gate_ctx`; only the four scale/shift terms are used —
/// the gates were folded into the projection weights at export, which is why
/// the residuals here are ungated.
public class DiffVAEDiffusionBlock: Module {
    @ModuleInfo(key: "context_proj") var contextProj: Linear
    @ModuleInfo(key: "norm1") var norm1: RMSNorm
    @ModuleInfo(key: "attn") var attn: DiffVAEAttention
    @ModuleInfo(key: "norm2") var norm2: RMSNorm
    @ModuleInfo(key: "mlp") var mlp: DiffVAESwiGLU
    @ParameterInfo(key: "scale_shift_table") var scaleShiftTable: MLXArray

    static let adaLNChunks = 7

    public init(dim: Int, kernel: (Int, Int, Int), contextChannels: Int, headDim: Int = 64) {
        self._contextProj.wrappedValue = Linear(contextChannels, dim, bias: true)
        self._norm1.wrappedValue = RMSNorm(dims: dim, eps: 1e-6)
        self._attn.wrappedValue = DiffVAEAttention(dim: dim, kernel: kernel, headDim: headDim)
        self._norm2.wrappedValue = RMSNorm(dims: dim, eps: 1e-6)
        self._mlp.wrappedValue = DiffVAESwiGLU(
            dim: dim, hidden: DiffVAESwiGLU.hiddenWidth(dim: dim))
        self._scaleShiftTable.wrappedValue = MLXArray.zeros([Self.adaLNChunks, dim])
        super.init()
    }

    /// - Parameters:
    ///   - contextAndX: `[B, T, H, W, contextChannels + dim]` — the context
    ///     volume and the noised pixels concatenated on the channel axis.
    ///   - modulation: the seven AdaLN chunks, each `[B, 1, 1, 1, dim]`.
    public func callAsFunction(_ contextAndX: MLXArray, modulation: [MLXArray]) -> MLXArray {
        let contextChannels = contextProj.weight.dim(1)
        let context = contextAndX[.ellipsis, 0 ..< contextChannels]
        var x = contextAndX[.ellipsis, contextChannels...]
        x = x + contextProj(context)

        func term(_ i: Int) -> MLXArray {
            modulation[i] + scaleShiftTable[i].reshaped([1, 1, 1, 1, -1])
        }
        let scaleMSA = term(0), shiftMSA = term(1)
        let scaleMLP = term(3), shiftMLP = term(4)

        x = x + attn(norm1(x) * (1.0 + scaleMSA) + shiftMSA)
        x = x + mlp(norm2(x) * (1.0 + scaleMLP) + shiftMLP)
        return x
    }
}

// MARK: - Upsample

/// Channel-expanding linear followed by a channels-last 3D pixel shuffle.
///
/// When the temporal stride is 2 the shuffle produces a duplicate leading
/// frame, which must be dropped to keep the causal 1→2 (composed 1→8) frame
/// mapping. Only the chunk holding the true temporal origin drops it.
public class DiffVAEUpsample: Module {
    let stride: (Int, Int, Int)
    let outChannels: Int

    @ModuleInfo(key: "proj") var proj: Linear

    public init(inChannels: Int, stride: (Int, Int, Int), reductionFactor: Int = 1) {
        self.stride = stride
        let cells = stride.0 * stride.1 * stride.2
        let projOut = cells * inChannels / reductionFactor
        self.outChannels = projOut / cells
        self._proj.wrappedValue = Linear(inChannels, projOut, bias: true)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, dropLeadingFrame: Bool = true) -> MLXArray {
        let (B, T, H, W) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        let (p1, p2, p3) = stride
        var h = proj(x)
        // The projection packs channels as (c, p1, p2, p3) — channel slowest,
        // width-stride fastest — so the shuffle reads that order, not (p, c).
        // Getting it backwards costs nothing structurally (shapes still match)
        // and everything numerically: measured 1.44 relative error against the
        // reference until this was fixed.
        h = h.reshaped([B, T, H, W, outChannels, p1, p2, p3])
            .transposed(0, 1, 5, 2, 6, 3, 7, 4)
            .reshaped([B, T * p1, H * p2, W * p3, outChannels])
        if p1 == 2 && dropLeadingFrame {
            h = h[0..., 1..., 0..., 0..., 0...]
        }
        return h
    }
}
