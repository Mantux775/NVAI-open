// VocoderWithBWE.swift - Vocoder + bandwidth extension (LTX-2.3 / 2.5)
// Copyright 2025

import Foundation
@preconcurrency import MLX
import MLXNN

// MARK: - Causal mel spectrogram

/// Log-mel spectrogram computed as a convolution against the checkpoint's own
/// DFT×Hann bases.
///
/// The bases are stored in the checkpoint rather than derived, so the mel values
/// handed to the bandwidth-extension generator are the ones it was trained on —
/// no window-convention drift. Padding is left-only, keeping the transform
/// causal: a frame never sees future samples.
final class MelSTFT: Module {
    @ParameterInfo(key: "mel_basis") var melBasis: MLXArray
    @ModuleInfo(key: "stft_fn") var stft: STFTBases

    let hopLength: Int
    let winLength: Int

    init(filterLength: Int = 512, hopLength: Int = 80, winLength: Int = 512, melChannels: Int = 64) {
        self.hopLength = hopLength
        self.winLength = winLength
        let freqs = filterLength / 2 + 1
        self._melBasis.wrappedValue = MLXArray.zeros([melChannels, freqs])
        self._stft.wrappedValue = STFTBases(filterLength: filterLength, hopLength: hopLength)
        super.init()
    }

    /// - Parameter waveform: `(B, T)`.
    /// - Returns: log-mel `(B, melChannels, frames)`.
    func logMel(_ waveform: MLXArray) -> MLXArray {
        let magnitude = stft.magnitude(waveform, winLength: winLength)
        let mel = MLX.matmul(melBasis.asType(magnitude.dtype), magnitude)
        return MLX.log(MLX.maximum(mel, MLXArray(Float(1e-5)).asType(mel.dtype)))
    }
}

/// The stored real/imaginary DFT bases, applied as a strided convolution.
final class STFTBases: Module {
    @ParameterInfo(key: "forward_basis") var forwardBasis: MLXArray
    @ParameterInfo(key: "inverse_basis") var inverseBasis: MLXArray

    private let filterLength: Int
    private let hopLength: Int

    init(filterLength: Int, hopLength: Int) {
        self.filterLength = filterLength
        self.hopLength = hopLength
        let rows = (filterLength / 2 + 1) * 2
        // Torch layout [rows, 1, filterLength]; transposed once at load time.
        self._forwardBasis.wrappedValue = MLXArray.zeros([rows, filterLength, 1])
        self._inverseBasis.wrappedValue = MLXArray.zeros([rows, filterLength, 1])
        super.init()
    }

    /// - Parameter waveform: `(B, T)`.
    /// - Returns: linear magnitude `(B, freqs, frames)`.
    func magnitude(_ waveform: MLXArray, winLength: Int) -> MLXArray {
        var x = waveform.expandedDimensions(axis: -1)              // (B, T, 1) — NLC
        let leftPad = max(0, winLength - hopLength)                 // causal: left only
        x = MLX.padded(x, widths: [.init((0, 0)), .init((leftPad, 0)), .init((0, 0))])

        let spec = MLX.conv1d(x, forwardBasis.asType(x.dtype), stride: hopLength, padding: 0)
        let freqs = spec.dim(2) / 2
        let real = spec[0..., 0..., 0 ..< freqs]
        let imag = spec[0..., 0..., freqs...]
        let magnitude = MLX.sqrt(real * real + imag * imag)
        return magnitude.transposed(0, 2, 1)                        // (B, freqs, frames)
    }
}

// MARK: - Vocoder with bandwidth extension

/// The full audio decode stage of LTX-2.3 / 2.5: a BigVGAN v2 vocoder at 16 kHz
/// followed by a bandwidth-extension generator that lifts it to 48 kHz.
///
/// The BWE runs the vocoder output back through a causal mel transform, predicts
/// a residual at the higher rate, and adds it to a sinc-resampled skip of the
/// original — so it adds detail rather than replacing the signal.
///
/// Both stages run in **float32**. The reference is explicit that bf16
/// accumulation across the ~108 sequential convolutions degrades spectral
/// metrics by 40–90%, and this is the one place in the pipeline where that
/// matters enough to break from the bf16 default.
final class LTXVocoderWithBWE: Module, LTXVocoding {
    @ModuleInfo(key: "vocoder") var vocoder: BigVGANGenerator
    @ModuleInfo(key: "bwe_generator") var bweGenerator: BigVGANGenerator
    @ModuleInfo(key: "mel_stft") var melSTFT: MelSTFT

    let inputSampleRate: Int
    let outputSampleRate: Int
    let hopLength: Int
    private let resampler: UpSample1d

    init(inputSampleRate: Int = 16000, outputSampleRate: Int = 48000, hopLength: Int = 80) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.hopLength = hopLength
        self._vocoder.wrappedValue = BigVGANGenerator(.vocoder)
        self._bweGenerator.wrappedValue = BigVGANGenerator(.bwe)
        self._melSTFT.wrappedValue = MelSTFT()
        // The skip resampler's kernel is not persisted upstream, so it is derived
        // here — the only filter in this stage not read from the checkpoint.
        let ratio = outputSampleRate / inputSampleRate
        self.resampler = UpSample1d(
            ratio: ratio, kernel: Self.hannSincKernel(ratio: ratio), hannWindow: true)
        super.init()
    }

    /// - Parameter melSpectrogram: `(B, 2, T, 64)`, as the audio VAE produces.
    /// - Returns: `(B, 2, samples)` at ``outputSampleRate``.
    func callAsFunction(_ melSpectrogram: MLXArray) -> MLXArray {
        var low = vocoder(melSpectrogram.asType(.float32))          // (B, T16, 2), NLC
        eval(low)

        let lowLength = low.dim(1)
        let outputLength = lowLength * outputSampleRate / inputSampleRate

        // Pad to a whole number of hops so the mel frame count is exact.
        let remainder = lowLength % hopLength
        if remainder != 0 {
            low = MLX.padded(
                low, widths: [.init((0, 0)), .init((0, hopLength - remainder)), .init((0, 0))])
        }

        // Per-channel mel: (B, T, 2) -> (B*2, T) -> log-mel -> (B, 2, T_frames, mel)
        let batch = low.dim(0)
        let channels = low.dim(2)
        let flat = low.transposed(0, 2, 1).reshaped([batch * channels, -1])
        let mel = melSTFT.logMel(flat)                              // (B*2, mel, frames)
        let melForBWE = mel.reshaped([batch, channels, mel.dim(1), mel.dim(2)])
            .transposed(0, 1, 3, 2)                                 // (B, 2, frames, mel)

        let residual = bweGenerator(melForBWE)                      // (B, T48, 2)
        let skip = resampler(low)
        eval(residual, skip)

        let length = min(residual.dim(1), skip.dim(1))
        var out = MLX.clip(
            residual[0..., 0 ..< length, 0...] + skip[0..., 0 ..< length, 0...],
            min: -1.0, max: 1.0)
        out = out[0..., 0 ..< min(outputLength, out.dim(1)), 0...]
        return out.transposed(0, 2, 1)                              // (B, 2, samples)
    }

    /// Hann-windowed sinc matching torchaudio's resampler, shaped `[1, 1, K]`.
    private static func hannSincKernel(ratio: Int) -> MLXArray {
        let rolloff: Float = 0.99
        let lowpassWidth: Float = 6
        let width = Int(ceil(lowpassWidth / rolloff))
        let kernelSize = 2 * width * ratio + 1

        var taps = [Float](repeating: 0, count: kernelSize)
        for i in 0 ..< kernelSize {
            let t = (Float(i) / Float(ratio) - Float(width)) * rolloff
            let clamped = max(-lowpassWidth, min(lowpassWidth, t))
            let window = pow(cos(clamped * .pi / lowpassWidth / 2), 2)
            let sinc: Float = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            taps[i] = sinc * window * rolloff / Float(ratio)
        }
        return MLXArray(taps).reshaped([1, 1, kernelSize])
    }
}
