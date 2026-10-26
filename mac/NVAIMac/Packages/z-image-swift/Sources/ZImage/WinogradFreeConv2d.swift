// Route for 3×3 convs inside mlx's Winograd conv2d window (mlx-swift ≤ 0.31.6 Metal numerics).
//
// mlx's Metal conv2d (mlx/backend/metal/conv.cpp `dispatch_conv_2D_gpu`) runs a Winograd
// F(6×6,3×3) kernel when ALL of these hold: kernel 3×3, stride 1, dilation 1, groups 1,
// C % 32 == 0, O % 32 == 0, C + O ≥ 256, N·H·W ≥ 4096. On M5 that path is lossy — relL2 per
// conv against an exact reference: fp32 6.4e-3 (its batched GEMM runs TF32, MLX_ENABLE_TF32
// defaults on, and the output transform amplifies that ~8×), bf16 5.8e-2, fp16 7.5e-3. Every
// other conv path is exact-class (fp32 ~1e-6; bf16 1.7e-3 = output rounding). conv3d with
// kT = 1 is the same conv on the implicit-GEMM path: exact, but 1.3–4× slower than Winograd at
// 256/512-channel shapes.
//
// The FLUX.1 AE hits the window in nearly every 3×3 conv: at 1024² that is 31 decoder convs
// (resnets 512/256/128-ch + upsamplers) and 21 encoder convs. Defaults: encoder `.conv3d` (its
// loss is material — 2.2e-2 in the img2img latent), decoder `.winograd` (its fp32 loss is below
// 8-bit visibility and the route costs +463 ms per 1024² decode; parity lanes opt in).
// Probe: `swift test --filter WinogradProbeTests` (weight-free). Removal: when the probe reports
// raw conv2d exact on a new mlx-swift pin, go back to plain Conv2d.
// `ZIMAGE_VAE_CONV_ROUTE=winograd|conv3d|fp32Winograd` overrides the defaults (validation).
//
// NVAI-open: the routing that lived in MLXExactConv (mlx-exact-conv-swift) is inlined here: the exact
// route is the kT = 1 conv3d form described above (exact on mlx-swift 0.31.x), the other two are plain
// conv2d. NVAI-open only decodes (T2I), where the default is mlx's Winograd path anyway.

import Foundation
import MLX
import MLXNN

/// How a 3×3 conv inside mlx's Winograd window runs. Shapes outside the window always take plain
/// conv2d, which is mlx's exact implicit-GEMM path.
public enum ZImageVAEConvRoute: String, Sendable {
    /// mlx's default Winograd kernel — fastest; on M5 ~6.4e-3 relL2 per conv in fp32, ~5.8e-2 in bf16.
    case winograd
    /// Exact implicit-GEMM path (MLXExactConv); the name is kept from the original kT = 1 conv3d route.
    case conv3d
    /// Half-precision input upcast to fp32 for the Winograd kernel and the result cast back:
    /// ~6.8e-3 per conv instead of bf16's ~5.8e-2, at fp32-Winograd speed. `.winograd` for fp32.
    case fp32Winograd

    /// `ZIMAGE_VAE_CONV_ROUTE` = winograd | conv3d | fp32Winograd, if set.
    static var environmentOverride: ZImageVAEConvRoute? {
        getenv("ZIMAGE_VAE_CONV_ROUTE").flatMap { ZImageVAEConvRoute(rawValue: String(cString: $0)) }
    }
}

final class WinogradFreeConv2d: Conv2d {
    var route: ZImageVAEConvRoute = .conv3d

    /// mlx's Winograd dispatch predicate, evaluated on the actual input (NHWC).
    static func takesWinograd(
        input x: MLXArray, weight: MLXArray, stride: (Int, Int), dilation: (Int, Int),
        groups: Int
    ) -> Bool {
        let (o, kh, kw, c) = (weight.dim(0), weight.dim(1), weight.dim(2), weight.dim(3))
        let nhw = x.dim(0) * x.dim(1) * x.dim(2)
        return kh == 3 && kw == 3 && stride == (1, 1) && dilation == (1, 1) && groups == 1
            && c % 32 == 0 && o % 32 == 0 && c + o >= 256 && nhw >= 4096
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let inWindow = Self.takesWinograd(input: x, weight: weight, stride: stride, dilation: dilation, groups: groups)
        var y: MLXArray
        switch route {
        case .conv3d where inWindow:
            // Exact implicit-GEMM path: the same conv with a temporal axis of length 1.
            let y3 = conv3d(x.expandedDimensions(axis: 1), weight.expandedDimensions(axis: 1),
                            stride: [1, stride.0, stride.1], padding: [0, padding.0, padding.1],
                            dilation: [1, dilation.0, dilation.1], groups: groups)
            y = y3.squeezed(axis: 1)
        case .fp32Winograd where inWindow && x.dtype != .float32:
            y = conv2d(x.asType(.float32), weight.asType(.float32), stride: [stride.0, stride.1],
                       padding: [padding.0, padding.1], dilation: [dilation.0, dilation.1], groups: groups)
                .asType(x.dtype)
        default:
            y = conv2d(x, weight, stride: [stride.0, stride.1], padding: [padding.0, padding.1],
                       dilation: [dilation.0, dilation.1], groups: groups)
        }
        if let bias { y = y + bias }
        return y
    }
}
