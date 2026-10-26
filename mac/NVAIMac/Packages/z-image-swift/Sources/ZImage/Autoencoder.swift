// FLUX.1 AutoencoderKL — Z-Image's VAE is literally the flux-dev AE
// (checkpoint vae/config.json `_name_or_path: "flux-dev"`): 16 latent channels,
// block_out_channels [128,256,512,512], 2 enc / 3 dec resnets, GroupNorm(32, eps 1e-6),
// SiLU, single-head mid attention, NO quant / post-quant convs, force_upcast → fp32.
//
// Copy-adapted from boogu-image-swift Sources/BooguImage/VAE.swift (same in-house
// flux-dev AE port, PSNR-gated there), itself isomorphic with diffusers AutoencoderKL —
// which is also what zimage-oracle src/zimage/autoencoder.py implements. Module/param
// names preserved so the checkpoint maps key-for-key; only Conv2d `.weight` needs the
// (O,I,H,W)->(O,H,W,I) transpose, done at load (Weights.swift). All convs run NHWC;
// tensors enter/exit decode()/encodeMoments() in NCHW (diffusers convention).
//
// Every stride-1 3×3 conv is a WinogradFreeConv2d: at ≥512² nearly all of them fall inside mlx's
// lossy Winograd conv2d window. The encoder reroutes those shapes through conv3d (kT = 1) by
// default; the decoder keeps mlx's Winograd path unless asked (`decoderConvRoute`). Numbers and
// removal path: WinogradFreeConv2d.swift, README "GPU numerics".

import Foundation
import MLX
import MLXFast
import MLXNN

private func silu(_ x: MLXArray) -> MLXArray { x * sigmoid(x) }

private func groupNorm(_ groups: Int, _ channels: Int, _ eps: Float) -> GroupNorm {
    GroupNorm(groupCount: groups, dimensions: channels, eps: eps, pytorchCompatible: true)
}

public struct ZImageVAEConfig: Codable, Sendable {
    public var inChannels: Int
    public var outChannels: Int
    public var latentChannels: Int
    public var blockOutChannels: [Int]
    public var layersPerBlock: Int
    public var normNumGroups: Int
    public var scalingFactor: Float
    public var shiftFactor: Float

    enum CodingKeys: String, CodingKey {
        case inChannels = "in_channels"
        case outChannels = "out_channels"
        case latentChannels = "latent_channels"
        case blockOutChannels = "block_out_channels"
        case layersPerBlock = "layers_per_block"
        case normNumGroups = "norm_num_groups"
        case scalingFactor = "scaling_factor"
        case shiftFactor = "shift_factor"
    }

    public static func load(_ url: URL) throws -> ZImageVAEConfig {
        try JSONDecoder().decode(ZImageVAEConfig.self, from: Data(contentsOf: url))
    }
}

final class ResnetBlock2D: Module {
    @ModuleInfo var norm1: GroupNorm
    @ModuleInfo var conv1: Conv2d
    @ModuleInfo var norm2: GroupNorm
    @ModuleInfo var conv2: Conv2d
    @ModuleInfo(key: "conv_shortcut") var convShortcut: Conv2d?

    init(_ inC: Int, _ outC: Int, groups: Int = 32, eps: Float = 1e-6) {
        self._norm1.wrappedValue = groupNorm(groups, inC, eps)
        self._conv1.wrappedValue = WinogradFreeConv2d(
            inputChannels: inC, outputChannels: outC, kernelSize: 3, stride: 1, padding: 1)
        self._norm2.wrappedValue = groupNorm(groups, outC, eps)
        self._conv2.wrappedValue = WinogradFreeConv2d(
            inputChannels: outC, outputChannels: outC, kernelSize: 3, stride: 1, padding: 1)
        if inC != outC {
            self._convShortcut.wrappedValue = Conv2d(
                inputChannels: inC, outputChannels: outC, kernelSize: 1, stride: 1, padding: 0)
        }
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var residual = x
        var h = conv1(silu(norm1(x)))
        h = conv2(silu(norm2(h)))
        if let convShortcut { residual = convShortcut(residual) }
        return residual + h
    }
}

/// diffusers Downsample2D: asymmetric pad (0,1,0,1) then stride-2 conv, pad=0.
final class Downsample2D: Module {
    @ModuleInfo var conv: Conv2d

    init(_ channels: Int) {
        self._conv.wrappedValue = Conv2d(
            inputChannels: channels, outputChannels: channels, kernelSize: 3, stride: 2, padding: 0)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // NHWC: pad bottom of H and right of W by 1.
        let padded = MLX.padded(x, widths: [.init((0, 0)), .init((0, 1)), .init((0, 1)), .init((0, 0))])
        return conv(padded)
    }
}

/// diffusers Upsample2D: nearest x2 then stride-1 conv, pad=1.
final class Upsample2D: Module {
    @ModuleInfo var conv: Conv2d

    init(_ channels: Int) {
        self._conv.wrappedValue = WinogradFreeConv2d(
            inputChannels: channels, outputChannels: channels, kernelSize: 3, stride: 1, padding: 1)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (b, h, w, c) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        var y = broadcast(
            x[0..., 0..., .newAxis, 0..., .newAxis, 0...], to: [b, h, 2, w, 2, c])
        y = y.reshaped(b, h * 2, w * 2, c)
        return conv(y)
    }
}

/// Single-head spatial self-attention used in the VAE mid block.
final class VAEAttention: Module {
    @ModuleInfo(key: "group_norm") var groupNorm_: GroupNorm
    @ModuleInfo(key: "to_q") var toQ: Linear
    @ModuleInfo(key: "to_k") var toK: Linear
    @ModuleInfo(key: "to_v") var toV: Linear
    @ModuleInfo(key: "to_out") var toOut: [Linear]
    let scale: Float

    init(_ channels: Int, groups: Int = 32, eps: Float = 1e-6) {
        self._groupNorm_.wrappedValue = groupNorm(groups, channels, eps)
        self._toQ.wrappedValue = Linear(channels, channels)
        self._toK.wrappedValue = Linear(channels, channels)
        self._toV.wrappedValue = Linear(channels, channels)
        self._toOut.wrappedValue = [Linear(channels, channels)]
        self.scale = 1.0 / Float(channels).squareRoot()
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (b, h, w, c) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        let residual = x
        var y = groupNorm_(x).reshaped(b, h * w, c)
        let q = toQ(y)
        let k = toK(y)
        let v = toV(y)
        let attn = softmax(matmul(q, k.transposed(0, 2, 1)) * scale, axis: -1)
        y = toOut[0](matmul(attn, v)).reshaped(b, h, w, c)
        return residual + y
    }
}

final class UNetMidBlock2D: Module {
    @ModuleInfo var resnets: [ResnetBlock2D]
    @ModuleInfo var attentions: [VAEAttention]

    init(_ channels: Int, groups: Int = 32, eps: Float = 1e-6) {
        self._resnets.wrappedValue = [
            ResnetBlock2D(channels, channels, groups: groups, eps: eps),
            ResnetBlock2D(channels, channels, groups: groups, eps: eps),
        ]
        self._attentions.wrappedValue = [VAEAttention(channels, groups: groups, eps: eps)]
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        resnets[1](attentions[0](resnets[0](x)))
    }
}

final class DownEncoderBlock2D: Module {
    @ModuleInfo var resnets: [ResnetBlock2D]
    @ModuleInfo var downsamplers: [Downsample2D]?

    init(_ inC: Int, _ outC: Int, numLayers: Int, addDownsample: Bool,
         groups: Int = 32, eps: Float = 1e-6) {
        self._resnets.wrappedValue = (0..<numLayers).map { i in
            ResnetBlock2D(i == 0 ? inC : outC, outC, groups: groups, eps: eps)
        }
        self._downsamplers.wrappedValue = addDownsample ? [Downsample2D(outC)] : nil
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for r in resnets { h = r(h) }
        if let downsamplers { h = downsamplers[0](h) }
        return h
    }
}

final class UpDecoderBlock2D: Module {
    @ModuleInfo var resnets: [ResnetBlock2D]
    @ModuleInfo var upsamplers: [Upsample2D]?

    init(_ inC: Int, _ outC: Int, numLayers: Int, addUpsample: Bool,
         groups: Int = 32, eps: Float = 1e-6) {
        self._resnets.wrappedValue = (0..<numLayers).map { i in
            ResnetBlock2D(i == 0 ? inC : outC, outC, groups: groups, eps: eps)
        }
        self._upsamplers.wrappedValue = addUpsample ? [Upsample2D(outC)] : nil
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for r in resnets { h = r(h) }
        if let upsamplers { h = upsamplers[0](h) }
        return h
    }
}

final class VAEEncoder: Module {
    @ModuleInfo(key: "conv_in") var convIn: Conv2d
    @ModuleInfo(key: "down_blocks") var downBlocks: [DownEncoderBlock2D]
    @ModuleInfo(key: "mid_block") var midBlock: UNetMidBlock2D
    @ModuleInfo(key: "conv_norm_out") var convNormOut: GroupNorm
    @ModuleInfo(key: "conv_out") var convOut: Conv2d

    init(_ inC: Int, _ latentC: Int, _ blockOut: [Int], layersPerBlock: Int,
         groups: Int = 32, eps: Float = 1e-6) {
        self._convIn.wrappedValue = WinogradFreeConv2d(
            inputChannels: inC, outputChannels: blockOut[0], kernelSize: 3, stride: 1, padding: 1)
        var blocks: [DownEncoderBlock2D] = []
        var outputChannel = blockOut[0]
        for (i, boc) in blockOut.enumerated() {
            let inputChannel = outputChannel
            outputChannel = boc
            blocks.append(DownEncoderBlock2D(
                inputChannel, outputChannel, numLayers: layersPerBlock,
                addDownsample: i != blockOut.count - 1, groups: groups, eps: eps))
        }
        self._downBlocks.wrappedValue = blocks
        self._midBlock.wrappedValue = UNetMidBlock2D(blockOut[blockOut.count - 1], groups: groups, eps: eps)
        self._convNormOut.wrappedValue = groupNorm(groups, blockOut[blockOut.count - 1], eps)
        self._convOut.wrappedValue = WinogradFreeConv2d(
            inputChannels: blockOut[blockOut.count - 1], outputChannels: 2 * latentC,
            kernelSize: 3, stride: 1, padding: 1)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = convIn(x)
        for b in downBlocks { h = b(h) }
        h = midBlock(h)
        return convOut(silu(convNormOut(h)))
    }
}

final class VAEDecoder: Module {
    @ModuleInfo(key: "conv_in") var convIn: Conv2d
    @ModuleInfo(key: "mid_block") var midBlock: UNetMidBlock2D
    @ModuleInfo(key: "up_blocks") var upBlocks: [UpDecoderBlock2D]
    @ModuleInfo(key: "conv_norm_out") var convNormOut: GroupNorm
    @ModuleInfo(key: "conv_out") var convOut: Conv2d

    init(_ outC: Int, _ latentC: Int, _ blockOut: [Int], layersPerBlock: Int,
         groups: Int = 32, eps: Float = 1e-6) {
        let reversed = Array(blockOut.reversed())
        self._convIn.wrappedValue = WinogradFreeConv2d(
            inputChannels: latentC, outputChannels: reversed[0], kernelSize: 3, stride: 1, padding: 1)
        self._midBlock.wrappedValue = UNetMidBlock2D(reversed[0], groups: groups, eps: eps)
        var blocks: [UpDecoderBlock2D] = []
        var outputChannel = reversed[0]
        for (i, boc) in reversed.enumerated() {
            let inputChannel = outputChannel
            outputChannel = boc
            blocks.append(UpDecoderBlock2D(
                inputChannel, outputChannel, numLayers: layersPerBlock + 1,
                addUpsample: i != reversed.count - 1, groups: groups, eps: eps))
        }
        self._upBlocks.wrappedValue = blocks
        self._convNormOut.wrappedValue = groupNorm(groups, reversed[reversed.count - 1], eps)
        self._convOut.wrappedValue = WinogradFreeConv2d(
            inputChannels: reversed[reversed.count - 1], outputChannels: outC,
            kernelSize: 3, stride: 1, padding: 1)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = convIn(x)
        h = midBlock(h)
        for b in upBlocks {
            if stageEval { eval(h) }
            h = b(h)
        }
        return convOut(silu(convNormOut(h)))
    }

    /// Realise the mid block and each up block before the next. Values are unchanged (max|Δ| 0);
    /// the decode transient falls ~19% (P3c: 15.08 → 12.33 GB at 1024², 59.12 → 47.13 at 2048²).
    /// As one lazy graph the up path dominates the decode, ahead of the mid attention's (h·w)²
    /// scores, so chunking those (AB-L-0176) saves nothing here. The up path cannot be halo-tiled
    /// exactly either: its GroupNorms take whole-frame statistics.
    var stageEval = true
}

/// FLUX.1 VAE. encodeMoments()/decode() take and return NCHW (diffusers convention).
public final class AutoencoderKL: Module {
    @ModuleInfo var encoder: VAEEncoder
    @ModuleInfo var decoder: VAEDecoder

    public let latentChannels: Int
    public let scalingFactor: Float
    public let shiftFactor: Float

    public init(_ cfg: ZImageVAEConfig, eps: Float = 1e-6) {
        self.latentChannels = cfg.latentChannels
        self.scalingFactor = cfg.scalingFactor
        self.shiftFactor = cfg.shiftFactor
        self._encoder.wrappedValue = VAEEncoder(
            cfg.inChannels, cfg.latentChannels, cfg.blockOutChannels,
            layersPerBlock: cfg.layersPerBlock, groups: cfg.normNumGroups, eps: eps)
        self._decoder.wrappedValue = VAEDecoder(
            cfg.outChannels, cfg.latentChannels, cfg.blockOutChannels,
            layersPerBlock: cfg.layersPerBlock, groups: cfg.normNumGroups, eps: eps)
        super.init()
        decoderConvRoute = .winograd
        if let route = ZImageVAEConvRoute.environmentOverride {
            encoderConvRoute = route
            decoderConvRoute = route
        }
    }

    /// Route for the encoder's in-window 3×3 convs (WinogradFreeConv2d.swift). Default `.conv3d`:
    /// the raw Winograd loss is material here (2.2e-2 in the img2img latent at 1024²).
    public var encoderConvRoute: ZImageVAEConvRoute {
        get { Self.route(of: encoder) }
        set { Self.setRoute(newValue, in: encoder) }
    }

    /// Route for the decoder's in-window 3×3 convs. Default `.winograd`: its fp32 loss is below
    /// 8-bit visibility (70 dB, ≤2 levels) and `.conv3d` costs +463 ms per 1024² decode — parity
    /// lanes opt in with `.conv3d`.
    public var decoderConvRoute: ZImageVAEConvRoute {
        get { Self.route(of: decoder) }
        set { Self.setRoute(newValue, in: decoder) }
    }

    static func route(of m: Module) -> ZImageVAEConvRoute {
        m.modules().lazy.compactMap { ($0 as? WinogradFreeConv2d)?.route }.first ?? .winograd
    }

    static func setRoute(_ route: ZImageVAEConvRoute, in m: Module) {
        for case let conv as WinogradFreeConv2d in m.modules() { conv.route = route }
    }

    /// Raw moments (mean, logvar concatenated on channel), NCHW in / NCHW out.
    public func encodeMoments(_ xNCHW: MLXArray) -> MLXArray {
        let x = xNCHW.transposed(0, 2, 3, 1)
        return encoder(x).transposed(0, 3, 1, 2)
    }

    public func decode(_ zNCHW: MLXArray) -> MLXArray {
        let z = zNCHW.transposed(0, 2, 3, 1)
        return decoder(z).transposed(0, 3, 1, 2)
    }
}
