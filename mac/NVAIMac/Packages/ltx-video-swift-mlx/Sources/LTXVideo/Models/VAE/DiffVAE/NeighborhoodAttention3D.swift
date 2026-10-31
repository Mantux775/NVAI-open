// NeighborhoodAttention3D.swift - Sliding-window 3D attention for the diffusion VAE
// Copyright 2026

import Foundation
@preconcurrency import MLX
import MLXFast
import MLXNN

/// 3D neighborhood attention: every token attends to a `(K_t, K_h, K_w)` window
/// centred on itself, clamped at the volume's borders.
///
/// The reference decoder runs this on NATTEN's fused CUDA kernels, with a
/// pure-PyTorch fallback that expands the window into an additive mask and
/// defers to standard attention. There is no NATTEN on Metal, so this is a port
/// of that fallback — same masks, same semantics, no kernel.
///
/// Two properties of the reference are load-bearing and reproduced exactly:
///
/// * **Border clamping, not truncation.** A window near an edge slides inward to
///   keep its full length (`start = min(max(i - half, 0), length - kernel)`)
///   rather than being cut short. Every query therefore sees exactly `kernel`
///   keys per axis, which is what the weights were trained against.
/// * **Kernel floor.** A kernel wider than the axis is clamped to the axis
///   length, so short clips (a single latent frame) stay valid instead of
///   indexing out of bounds.
///
/// The mask is built once per *tile geometry* and reused across the tiles that
/// share it, which is what keeps the memory bounded: a full `[N, N]` mask over a
/// 768×512 stage-5 volume would be terabytes, while tiles keep each mask inside
/// ``scoreBudget`` elements.
public enum NeighborhoodAttention3D {

    /// Element budget for one tile's `[queries, keys]` score matrix.
    /// Mirrors the reference fallback's `NA_SCORE_BUDGET`. Settable so a test
    /// can force real tiling on a volume small enough to brute-force — without
    /// that, equivalence tests only ever exercise the single-tile path, which
    /// is how a mask-cache collision reached the decoder unnoticed.
    nonisolated(unsafe) static var scoreBudget = 32 * 1024 * 1024

    /// Per-index `(start, end)` of the attended window along one axis.
    ///
    /// Non-causal is the clamped-window rule described above; causal keeps the
    /// trailing `kernel` positions, which the decoder uses on the time axis when
    /// a stage is declared causal.
    static func windowBounds(
        length: Int, kernel: Int, causal: Bool
    ) -> (starts: [Int], ends: [Int]) {
        var starts = [Int](), ends = [Int]()
        starts.reserveCapacity(length); ends.reserveCapacity(length)
        if causal {
            for i in 0 ..< length {
                starts.append(max(0, i - kernel + 1))
                ends.append(i + 1)
            }
        } else {
            let k = min(kernel, length)
            let lo = length - k
            let half = k / 2
            for i in 0 ..< length {
                let start = min(max(i - half, 0), lo)
                starts.append(start)
                ends.append(start + k)
            }
        }
        return (starts, ends)
    }

    /// Per-axis query-tile lengths that keep one tile's score matrix under
    /// ``scoreBudget``. Halves the axis with the largest tile-to-kernel ratio
    /// until it fits — the reference's heuristic, kept identical so tile
    /// geometries (and therefore numerics at the seams) match.
    static func pickTiles(dims: (Int, Int, Int), kernels: (Int, Int, Int)) -> (Int, Int, Int) {
        var tiles = [dims.0, dims.1, dims.2]
        let k = [kernels.0, kernels.1, kernels.2]
        let d = [dims.0, dims.1, dims.2]

        func cost(_ ts: [Int]) -> Int {
            let nq = ts.reduce(1, *)
            let nk = (0 ..< 3).map { min(d[$0], ts[$0] + k[$0] - 1) }.reduce(1, *)
            return nq * nk
        }

        while cost(tiles) > scoreBudget && tiles.max()! > 1 {
            let i = (0 ..< 3).max { Double(tiles[$0]) / Double(k[$0]) < Double(tiles[$1]) / Double(k[$1]) }!
            if tiles[i] <= 1 { break }
            tiles[i] = max(1, (tiles[i] + 1) / 2)
        }
        return (tiles[0], tiles[1], tiles[2])
    }

    /// Additive `[1, 1, Nq, Nk]` mask for one tile geometry, where each axis
    /// contributes its own visibility pattern and the 3D mask is their product.
    static func groupMask(
        bounds: [(starts: [Int], ends: [Int])],
        keyLengths: [Int],
        dtype: DType
    ) -> MLXArray {
        var axisMasks: [MLXArray] = []
        for (axis, b) in bounds.enumerated() {
            let st = MLXArray(b.starts.map { Int32($0) })
            let en = MLXArray(b.ends.map { Int32($0) })
            let kj = MLXArray(0 ..< keyLengths[axis]).asType(.int32)
            // [queriesOnAxis, keysOnAxis]
            axisMasks.append((kj[.newAxis, 0...] .>= st[0..., .newAxis])
                & (kj[.newAxis, 0...] .< en[0..., .newAxis]))
        }
        // Outer product over the three axes → [qt, qh, qw, kt, kh, kw]
        let a = axisMasks[0][0..., .newAxis, .newAxis, 0..., .newAxis, .newAxis]
        let b = axisMasks[1][.newAxis, 0..., .newAxis, .newAxis, 0..., .newAxis]
        let c = axisMasks[2][.newAxis, .newAxis, 0..., .newAxis, .newAxis, 0...]
        let visible = a & b & c

        let nq = visible.dim(0) * visible.dim(1) * visible.dim(2)
        let nk = visible.dim(3) * visible.dim(4) * visible.dim(5)
        let flat = visible.reshaped([nq, nk])
        let neg = MLXArray(-Float.greatestFiniteMagnitude).asType(dtype)
        let zero = MLXArray(Float(0)).asType(dtype)
        return MLX.where(flat, zero, neg).reshaped([1, 1, nq, nk])
    }

    /// Neighborhood attention over a `(T, H, W)` volume.
    ///
    /// - Parameters:
    ///   - q, k, v: `[B, heads, T, H, W, headDim]`
    ///   - kernels: `(K_t, K_h, K_w)`, clamped per axis to the volume
    ///   - causalTime: causal window on the time axis
    ///   - scale: attention scale; the caller applies it since q/k are pre-normed
    /// - Returns: `[B, heads, T, H, W, headDim]`
    public static func callAsFunction(
        q: MLXArray, k: MLXArray, v: MLXArray,
        dims: (Int, Int, Int),
        kernels: (Int, Int, Int),
        causalTime: Bool = false,
        scale: Float = 1.0
    ) -> MLXArray {
        let (T, H, W) = dims
        let kt = min(kernels.0, T), kh = min(kernels.1, H), kw = min(kernels.2, W)
        let B = q.dim(0), heads = q.dim(1), headDim = q.dim(5)

        let bounds = [
            windowBounds(length: T, kernel: kt, causal: causalTime),
            windowBounds(length: H, kernel: kh, causal: false),
            windowBounds(length: W, kernel: kw, causal: false),
        ]
        let tiles = pickTiles(dims: dims, kernels: (kt, kh, kw))

        let output = MLXArray.zeros(like: q)
        var maskCache: [String: MLXArray] = [:]
        // A large volume splits into hundreds of tiles. Left lazy, they queue
        // into one Metal command buffer and trip the GPU watchdog, so the graph
        // is materialised every few tiles — the cost is bounded, the result
        // identical.
        var tilesSinceEval = 0
        let evalEvery = 16

        // Walk query tiles; each tile reads the union of its queries' windows.
        for t0 in stride(from: 0, to: T, by: tiles.0) {
            let t1 = min(t0 + tiles.0, T)
            for h0 in stride(from: 0, to: H, by: tiles.1) {
                let h1 = min(h0 + tiles.1, H)
                for w0 in stride(from: 0, to: W, by: tiles.2) {
                    let w1 = min(w0 + tiles.2, W)

                    let ranges = [(t0, t1), (h0, h1), (w0, w1)]
                    // Key span per axis = union of the tile's query windows.
                    var keySpans: [(Int, Int)] = []
                    var relBounds: [(starts: [Int], ends: [Int])] = []
                    for axis in 0 ..< 3 {
                        let (lo, hi) = ranges[axis]
                        let s = bounds[axis].starts[lo ..< hi].min()!
                        let e = bounds[axis].ends[lo ..< hi].max()!
                        keySpans.append((s, e))
                        relBounds.append((
                            starts: bounds[axis].starts[lo ..< hi].map { $0 - s },
                            ends: bounds[axis].ends[lo ..< hi].map { $0 - s }))
                    }

                    let keyLengths = keySpans.map { $0.1 - $0.0 }
                    let qShape = [t1 - t0, h1 - h0, w1 - w0]
                    // Tiles with identical geometry share a mask. The key carries
                    // the *whole* window pattern: a border tile, whose windows
                    // clamp, otherwise shares "first start / last end" with an
                    // interior tile whose windows slide — same key, wrong mask,
                    // and a silent error confined to the borders.
                    let key = "\(qShape)|\(keyLengths)|"
                        + relBounds.map { "\($0.starts)>\($0.ends)" }.joined(separator: ";")
                    let mask: MLXArray
                    if let cached = maskCache[key] {
                        mask = cached
                    } else {
                        mask = groupMask(bounds: relBounds, keyLengths: keyLengths, dtype: q.dtype)
                        maskCache[key] = mask
                    }

                    let qTile = q[0..., 0..., t0 ..< t1, h0 ..< h1, w0 ..< w1, 0...]
                        .reshaped([B, heads, qShape.reduce(1, *), headDim])
                    let kTile = k[0..., 0..., keySpans[0].0 ..< keySpans[0].1,
                                  keySpans[1].0 ..< keySpans[1].1,
                                  keySpans[2].0 ..< keySpans[2].1, 0...]
                        .reshaped([B, heads, keyLengths.reduce(1, *), headDim])
                    let vTile = v[0..., 0..., keySpans[0].0 ..< keySpans[0].1,
                                  keySpans[1].0 ..< keySpans[1].1,
                                  keySpans[2].0 ..< keySpans[2].1, 0...]
                        .reshaped([B, heads, keyLengths.reduce(1, *), headDim])

                    let out = MLXFast.scaledDotProductAttention(
                        queries: qTile, keys: kTile, values: vTile, scale: scale, mask: mask)
                    output[0..., 0..., t0 ..< t1, h0 ..< h1, w0 ..< w1, 0...] =
                        out.reshaped([B, heads, qShape[0], qShape[1], qShape[2], headDim])
                    tilesSinceEval += 1
                    if tilesSinceEval >= evalEvery {
                        MLX.eval(output)
                        tilesSinceEval = 0
                    }
                }
            }
        }
        return output
    }
}
