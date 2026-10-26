// SPDX-License-Identifier: MIT (port). SeedVR2 model/weights: Apache-2.0 / ByteDance.
//
// Port of mflux seedvr2_util._lab_color_transfer_exact — the post-process that keeps
// SeedVR2's refined detail but transfers the input's color/lighting base:
//   1. wavelet reconstruction: content's high-freq + style's low-freq
//   2. LAB histogram-match a/b (and a luminance-weighted L) of content toward style
// Operates on [B,3,H,W] in [-1,1]. All elementwise + sort ops (MLX-Swift native).
import Foundation
import MLX

public enum SeedVR2ColorCorrect {

    /// content/style: [B,3,H,W] in [-1,1]. Returns corrected content in [-1,1].
    public static func labTransfer(content: MLXArray, style: MLXArray, luminanceWeight: Float = 0.8) -> MLXArray {
        let recon = waveletReconstruction(content: content, style: style)   // [B,3,H,W] in [-1,1]

        // -> [B,H,W,3] in [0,1]
        let c = clip((recon.transposed(0, 2, 3, 1) + 1) * 0.5, min: 0, max: 1)
        let s = clip((style.transposed(0, 2, 3, 1) + 1) * 0.5, min: 0, max: 1)
        let cLab = rgbToLab(c), sLab = rgbToLab(s)

        let matchedA = histMatch(cLab[.ellipsis, 1], sLab[.ellipsis, 1])
        let matchedB = histMatch(cLab[.ellipsis, 2], sLab[.ellipsis, 2])
        let L: MLXArray
        if luminanceWeight < 1.0 {
            let matchedL = histMatch(cLab[.ellipsis, 0], sLab[.ellipsis, 0])
            L = luminanceWeight * cLab[.ellipsis, 0] + (1 - luminanceWeight) * matchedL
        } else {
            L = cLab[.ellipsis, 0]
        }
        let outLab = stacked([L, matchedA, matchedB], axis: -1)
        let outRgb = clip(labToRgb(outLab), min: 0, max: 1)
        return (outRgb * 2 - 1).transposed(0, 3, 1, 2)   // back to [B,3,H,W] in [-1,1]
    }

    // MARK: wavelet (à trous) — 3×3 [1,2,1;2,4,2;1,2,1]/16 with dilation = radius

    private static let blurTaps: [(Int, Int, Float)] = [
        (-1, -1, 1 / 16), (-1, 0, 2 / 16), (-1, 1, 1 / 16),
        (0, -1, 2 / 16), (0, 0, 4 / 16), (0, 1, 2 / 16),
        (1, -1, 1 / 16), (1, 0, 2 / 16), (1, 1, 1 / 16),
    ]

    private static func waveletBlur(_ x: MLXArray, radius: Int) -> MLXArray {
        let s = x.shape, (H, W) = (s[2], s[3])
        let p = max(radius, 1)
        let padded = MLX.padded(x, widths: [.init((0, 0)), .init((0, 0)), .init((p, p)), .init((p, p))], mode: .edge)
        var out = MLXArray.zeros(like: x)
        for (dy, dx, w) in blurTaps {
            let ys = p + dy * radius, xs = p + dx * radius
            out = out + w * padded[0..., 0..., ys ..< (ys + H), xs ..< (xs + W)]
        }
        return out
    }

    /// Returns (high-freq, low-freq) over `levels` à-trous scales.
    private static func waveletDecomposition(_ image: MLXArray, levels: Int = 5) -> (MLXArray, MLXArray) {
        var high = MLXArray.zeros(like: image)
        var cur = image
        for i in 0 ..< levels {
            let low = waveletBlur(cur, radius: 1 << i)
            high = high + (cur - low)
            cur = low
        }
        return (high, cur)
    }

    private static func waveletReconstruction(content: MLXArray, style: MLXArray) -> MLXArray {
        let (contentHigh, _) = waveletDecomposition(content)
        let (_, styleLow) = waveletDecomposition(style)
        return clip(contentHigh + styleLow, min: -1, max: 1)
    }

    // MARK: sRGB <-> CIELAB (D65)

    private static let mRGB2XYZ = MLXArray(converting: [
        0.4124564, 0.3575761, 0.1804375,
        0.2126729, 0.7151522, 0.0721750,
        0.0193339, 0.1191920, 0.9503041,
    ]).reshaped([3, 3])
    private static let mXYZ2RGB = MLXArray(converting: [
        3.2404542, -1.5371385, -0.4985314,
        -0.9692660, 1.8760108, 0.0415560,
        0.0556434, -0.2040259, 1.0572252,
    ]).reshaped([3, 3])
    private static let eps: Float = 6.0 / 29.0
    private static var eps3: Float { eps * eps * eps }
    private static var kappa: Float { let k = 29.0 / 3.0; return Float(k * k * k) }

    private static func rgbToLab(_ rgb: MLXArray) -> MLXArray {
        let lin = MLX.where(rgb .> 0.04045, pow((rgb + 0.055) / 1.055, 2.4), rgb / 12.92)
        var xyz = matmul(lin, mRGB2XYZ.transposed())          // [...,3]
        xyz = xyz / MLXArray(converting: [0.95047, 1.0, 1.08883])
        let f = MLX.where(xyz .> eps3, pow(xyz, 1.0 / 3.0), (kappa * xyz + 16) / 116)
        let (fx, fy, fz) = (f[.ellipsis, 0], f[.ellipsis, 1], f[.ellipsis, 2])
        return stacked([116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)], axis: -1)
    }

    private static func labToRgb(_ lab: MLXArray) -> MLXArray {
        let (L, a, b) = (lab[.ellipsis, 0], lab[.ellipsis, 1], lab[.ellipsis, 2])
        let fy = (L + 16) / 116, fx = a / 500 + fy, fz = fy - b / 200
        func finv(_ t: MLXArray) -> MLXArray { MLX.where(t .> eps, pow(t, 3), (116 * t - 16) / kappa) }
        var xyz = stacked([finv(fx), finv(fy), finv(fz)], axis: -1)
        xyz = xyz * MLXArray(converting: [0.95047, 1.0, 1.08883])
        let lin = matmul(xyz, mXYZ2RGB.transposed())
        return MLX.where(lin .> 0.0031308, 1.055 * pow(maximum(lin, 0), 1.0 / 2.4) - 0.055, 12.92 * lin)
    }

    // MARK: exact (rank-based) histogram matching, per batch

    /// source/reference: [B,H,W] -> source values replaced by reference values at equal rank.
    private static func histMatch(_ source: MLXArray, _ reference: MLXArray) -> MLXArray {
        let B = source.shape[0]
        var outs: [MLXArray] = []
        for b in 0 ..< B {
            let hw = [source.shape[1], source.shape[2]]
            let src = source[b].reshaped([-1]), ref = reference[b].reshaped([-1])
            let srcIdx = argSort(src, axis: 0)
            let refSorted = sorted(ref, axis: 0)
            let inv = argSort(srcIdx, axis: 0)        // inverse permutation = ranks
            outs.append(refSorted[inv].reshaped(hw))
        }
        return stacked(outs, axis: 0)
    }
}
