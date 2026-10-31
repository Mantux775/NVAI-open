// BigVGANVocoder.swift - The vocoder LTX-2.3 / 2.5 checkpoints actually ship
// Copyright 2025

import Foundation
@preconcurrency import MLX
import MLXNN

// MARK: - Snake activations

/// SnakeBeta: `x + (1 / (β + ε)) · sin²(αx)`, with α and β learned per channel.
///
/// Both are stored in log scale (`alpha_logscale`), so the checkpoint holds
/// `log α` and `log β` and the forward exponentiates. A checkpoint value of 0
/// therefore means α = 1, not α = 0.
final class SnakeBeta: Module {
    @ParameterInfo(key: "alpha") var alpha: MLXArray
    @ParameterInfo(key: "beta") var beta: MLXArray

    private let eps: Float = 1e-9

    init(channels: Int) {
        self._alpha.wrappedValue = MLXArray.zeros([channels])
        self._beta.wrappedValue = MLXArray.zeros([channels])
        super.init()
    }

    /// `x` is NLC — the channel axis is last, so the per-channel parameters
    /// broadcast without reshaping.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let a = MLX.exp(alpha)
        let b = MLX.exp(beta)
        let s = MLX.sin(x * a)
        return x + (1.0 / (b + eps)) * (s * s)
    }
}

// MARK: - Anti-aliased resampling

/// Depthwise low-pass filter, the `LowPassFilter1d` of BigVGAN v2.
///
/// The kernel is a Kaiser-windowed sinc. It is **not** recomputed here: the
/// checkpoint stores it as a persistent buffer, so loading it verbatim removes
/// any chance of drifting from the window the model was trained with.
final class LowPassFilter1d: Module {
    @ParameterInfo(key: "filter") var filter: MLXArray

    let stride: Int
    let padLeft: Int
    let padRight: Int
    private let kernelSize: Int

    init(kernelSize: Int = 12, stride: Int = 1) {
        self.kernelSize = kernelSize
        self.stride = stride
        let even = kernelSize % 2 == 0
        self.padLeft = kernelSize / 2 - (even ? 1 : 0)
        self.padRight = kernelSize / 2
        // Checkpoint layout is torch's [1, 1, K]; kept as-is and expanded per call.
        self._filter.wrappedValue = MLXArray.zeros([1, 1, kernelSize])
        super.init()
    }

    /// `x`: NLC. Returns NLC.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let channels = x.dim(2)
        let padded = MLX.padded(
            x, widths: [.init((0, 0)), .init((padLeft, padRight)), .init((0, 0))], mode: .edge)
        // Depthwise: one filter tap set per channel, groups == channels.
        let weight = MLX.broadcast(
            filter.reshaped([1, kernelSize, 1]), to: [channels, kernelSize, 1]
        ).asType(padded.dtype)
        return MLX.conv1d(padded, weight, stride: stride, padding: 0, groups: channels)
    }
}

/// `UpSample1d`: transposed depthwise convolution with the same Kaiser kernel,
/// scaled by the ratio and cropped back to the exact expected length.
final class UpSample1d: Module {
    @ParameterInfo(key: "filter") var filter: MLXArray

    let ratio: Int
    private let kernelSize: Int
    private let pad: Int
    private let padLeft: Int
    private let padRight: Int

    /// - Parameter kernel: an explicit kernel, for the one filter the checkpoint
    ///   does not carry (the BWE skip resampler is `persistent=False` upstream).
    init(ratio: Int = 2, kernelSize: Int = 12, kernel: MLXArray? = nil, hannWindow: Bool = false) {
        self.ratio = ratio
        if hannWindow {
            // torchaudio-equivalent Hann-windowed sinc, used only by the BWE skip path.
            let rolloff: Float = 0.99
            let lowpassWidth = 6
            let width = Int(ceil(Float(lowpassWidth) / rolloff))
            self.kernelSize = 2 * width * ratio + 1
            self.pad = width
            self.padLeft = 2 * width * ratio
            self.padRight = self.kernelSize - ratio
        } else {
            self.kernelSize = kernelSize
            self.pad = kernelSize / ratio - 1
            self.padLeft = self.pad * ratio + (kernelSize - ratio) / 2
            self.padRight = self.pad * ratio + (kernelSize - ratio + 1) / 2
        }
        self._filter.wrappedValue = kernel ?? MLXArray.zeros([1, 1, self.kernelSize])
        super.init()
    }

    /// `x`: NLC. Returns NLC, `ratio` times longer.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let channels = x.dim(2)
        let padded = MLX.padded(
            x, widths: [.init((0, 0)), .init((pad, pad)), .init((0, 0))], mode: .edge)
        let weight = MLX.broadcast(
            filter.reshaped([1, kernelSize, 1]), to: [channels, kernelSize, 1]
        ).asType(padded.dtype)
        var out = MLX.convTransposed1d(
            padded, weight, stride: ratio, padding: 0, groups: channels)
        out = out * MLXArray(Float(ratio)).asType(out.dtype)
        return out[0..., padLeft ..< (out.dim(1) - padRight), 0...]
    }
}

/// Up-sample, activate, down-sample — BigVGAN v2's anti-aliased nonlinearity.
/// The activation runs at `ratio`× the rate so its harmonics stay below Nyquist.
final class Activation1d: Module {
    @ModuleInfo(key: "act") var act: SnakeBeta
    @ModuleInfo(key: "upsample") var upsample: UpSample1d
    @ModuleInfo(key: "downsample") var downsample: DownSample1d

    init(channels: Int, upRatio: Int = 2, downRatio: Int = 2, kernelSize: Int = 12) {
        self._act.wrappedValue = SnakeBeta(channels: channels)
        self._upsample.wrappedValue = UpSample1d(ratio: upRatio, kernelSize: kernelSize)
        self._downsample.wrappedValue = DownSample1d(ratio: downRatio, kernelSize: kernelSize)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downsample(act(upsample(x)))
    }
}

/// `DownSample1d` — a strided low-pass, matching the checkpoint's nesting
/// (`downsample.lowpass.filter`).
final class DownSample1d: Module {
    @ModuleInfo(key: "lowpass") var lowpass: LowPassFilter1d

    init(ratio: Int = 2, kernelSize: Int = 12) {
        self._lowpass.wrappedValue = LowPassFilter1d(kernelSize: kernelSize, stride: ratio)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { lowpass(x) }
}

// MARK: - AMP block

/// `AMPBlock1`: three residual pairs of (anti-aliased activation → dilated conv →
/// anti-aliased activation → conv).
final class AMPBlock1: Module {
    @ModuleInfo(key: "convs1") var convs1: [Conv1d]
    @ModuleInfo(key: "convs2") var convs2: [Conv1d]
    @ModuleInfo(key: "acts1") var acts1: [Activation1d]
    @ModuleInfo(key: "acts2") var acts2: [Activation1d]

    init(channels: Int, kernelSize: Int, dilations: [Int]) {
        func padding(_ k: Int, _ d: Int) -> Int { (k * d - d) / 2 }

        self._convs1.wrappedValue = dilations.map {
            Conv1d(inputChannels: channels, outputChannels: channels,
                   kernelSize: kernelSize, padding: padding(kernelSize, $0), dilation: $0)
        }
        self._convs2.wrappedValue = dilations.map { _ in
            Conv1d(inputChannels: channels, outputChannels: channels,
                   kernelSize: kernelSize, padding: padding(kernelSize, 1), dilation: 1)
        }
        self._acts1.wrappedValue = dilations.map { _ in Activation1d(channels: channels) }
        self._acts2.wrappedValue = dilations.map { _ in Activation1d(channels: channels) }
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = x
        for i in 0 ..< convs1.count {
            var xt = acts1[i](out)
            xt = convs1[i](xt)
            xt = acts2[i](xt)
            xt = convs2[i](xt)
            out = out + xt
        }
        return out
    }
}

// MARK: - Generator

/// BigVGAN v2 generator: the mel→waveform stage LTX-2.3 and LTX-2.5 ship.
///
/// Used twice by ``LTXVocoderWithBWE`` — once as the base vocoder, once as the
/// bandwidth-extension generator — with different channel counts and rates.
final class BigVGANGenerator: Module {
    @ModuleInfo(key: "conv_pre") var convPre: Conv1d
    @ModuleInfo(key: "ups") var ups: [ConvTransposed1d]
    @ModuleInfo(key: "resblocks") var resblocks: [AMPBlock1]
    @ModuleInfo(key: "act_post") var actPost: Activation1d
    @ModuleInfo(key: "conv_post") var convPost: Conv1d

    let numKernels: Int
    private let applyFinalActivation: Bool
    private let useTanhAtFinal: Bool

    struct Config {
        var upsampleInitialChannel: Int
        var upsampleRates: [Int]
        var upsampleKernelSizes: [Int]
        var resblockKernelSizes: [Int] = [3, 7, 11]
        var resblockDilations: [[Int]] = [[1, 3, 5], [1, 3, 5], [1, 3, 5]]
        var applyFinalActivation: Bool = true
        var useTanhAtFinal: Bool = false
        var useBiasAtFinal: Bool = false

        /// Base vocoder: audio latents → 16 kHz stereo.
        static let vocoder = Config(
            upsampleInitialChannel: 1536,
            upsampleRates: [5, 2, 2, 2, 2, 2],
            upsampleKernelSizes: [11, 4, 4, 4, 4, 4])

        /// Bandwidth extension: 16 kHz mel → 48 kHz stereo residual.
        static let bwe = Config(
            upsampleInitialChannel: 512,
            upsampleRates: [6, 5, 2, 2, 2],
            upsampleKernelSizes: [12, 11, 4, 4, 4],
            applyFinalActivation: false)
    }

    init(_ config: Config) {
        self.numKernels = config.resblockKernelSizes.count
        self.applyFinalActivation = config.applyFinalActivation
        self.useTanhAtFinal = config.useTanhAtFinal

        // Stereo everywhere: 128 = 2 channels x 64 mel bins in, 2 channels out.
        self._convPre.wrappedValue = Conv1d(
            inputChannels: 128, outputChannels: config.upsampleInitialChannel,
            kernelSize: 7, padding: 3)

        var upsamplers: [ConvTransposed1d] = []
        var blocks: [AMPBlock1] = []
        for (i, (stride, kernel)) in zip(config.upsampleRates, config.upsampleKernelSizes).enumerated() {
            let inCh = config.upsampleInitialChannel / (1 << i)
            let outCh = config.upsampleInitialChannel / (1 << (i + 1))
            upsamplers.append(ConvTransposed1d(
                inputChannels: inCh, outputChannels: outCh,
                kernelSize: kernel, stride: stride, padding: (kernel - stride) / 2))
            for (k, dilations) in zip(config.resblockKernelSizes, config.resblockDilations) {
                blocks.append(AMPBlock1(channels: outCh, kernelSize: k, dilations: dilations))
            }
        }
        self._ups.wrappedValue = upsamplers
        self._resblocks.wrappedValue = blocks

        let finalChannels = config.upsampleInitialChannel / (1 << config.upsampleRates.count)
        self._actPost.wrappedValue = Activation1d(channels: finalChannels)
        self._convPost.wrappedValue = Conv1d(
            inputChannels: finalChannels, outputChannels: 2,
            kernelSize: 7, padding: 3, bias: config.useBiasAtFinal)
        super.init()
    }

    /// - Parameter melSpectrogram: `(B, 2, T, melBins)` stereo.
    /// - Returns: `(B, T_audio, 2)` in NLC — the caller transposes if it wants NCL.
    func callAsFunction(_ melSpectrogram: MLXArray) -> MLXArray {
        // (B, 2, T, mel) -> (B, 2, mel, T) -> (B, 2*mel, T) -> NLC
        var x = melSpectrogram.transposed(0, 1, 3, 2)
        x = x.reshaped([x.dim(0), x.dim(1) * x.dim(2), x.dim(3)])
        x = x.transposed(0, 2, 1)

        x = convPre(x)

        for (i, up) in ups.enumerated() {
            x = up(x)
            // The parallel resblocks all consume the same input and are averaged.
            let start = i * numKernels
            var summed = resblocks[start](x)
            for j in 1 ..< numKernels {
                summed = summed + resblocks[start + j](x)
            }
            x = summed / MLXArray(Float(numKernels)).asType(summed.dtype)
            eval(x)
        }

        x = actPost(x)
        x = convPost(x)
        if applyFinalActivation {
            x = useTanhAtFinal ? MLX.tanh(x) : MLX.clip(x, min: -1.0, max: 1.0)
        }
        return x
    }
}
