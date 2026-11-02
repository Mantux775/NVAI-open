//
//  MelSpectrogram.swift
//  MLXAudioSTT
//
// Created by Prince Canuma on 04/01/2026.
//

import Foundation
import MLX

// NVAI-open: only the helpers the Qwen3-TTS speaker encoder needs, from MLXAudioCore/DSP.swift
// (internal here instead of public).

/// Create a Hanning window of given size.
/// `periodic: true` matches `torch.hann_window` (librosa/Whisper default);
/// the previous symmetric-only form is kept as default for compatibility.
func hanningWindow(size: Int, periodic: Bool = false) -> MLXArray {
    let effectiveSize = periodic ? size + 1 : size
    let denom = Float(effectiveSize - 1)
    var window = [Float](repeating: 0, count: size)
    for n in 0..<size {
        window[n] = 0.5 * (1 - cos(2 * Float.pi * Float(n) / denom))
    }
    return MLXArray(window)
}

/// Mel scale variants for filterbank computation.
enum MelScale {
    /// HTK formula: mel = 2595 * log10(1 + f/700)
    case htk
    /// Slaney (Auditory Toolbox): linear below 1000 Hz, logarithmic above
    case slaney
}

/// Create mel filterbank matrix.
func melFilters(
    sampleRate: Int,
    nFft: Int,
    nMels: Int,
    fMin: Float = 0,
    fMax: Float? = nil,
    norm: String? = "slaney",
    melScale: MelScale = .htk
) -> MLXArray {
    let fMaxVal = fMax ?? Float(sampleRate) / 2.0

    let nFreqs = nFft / 2 + 1

    // Generate frequency points
    var allFreqs = [Float](repeating: 0, count: nFreqs)
    for i in 0..<nFreqs {
        allFreqs[i] = Float(i) * Float(sampleRate) / Float(nFft)
    }

    // Mel scale conversion functions
    let hzToMel: (Float) -> Float
    let melToHz: (Float) -> Float

    switch melScale {
    case .htk:
        hzToMel = { freq in 2595.0 * log10(1.0 + freq / 700.0) }
        melToHz = { mel in 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

    case .slaney:
        // Slaney (Auditory Toolbox) piecewise linear/log scale
        let fSp: Float = 200.0 / 3.0
        let minLogHz: Float = 1000.0
        let minLogMel = (minLogHz - fMin) / fSp
        let logStep = log(Float(6.4)) / 27.0

        hzToMel = { freq in
            if freq < minLogHz {
                return (freq - fMin) / fSp
            } else {
                return minLogMel + log(freq / minLogHz) / logStep
            }
        }
        melToHz = { mel in
            if mel < minLogMel {
                return fMin + fSp * mel
            } else {
                return minLogHz * exp(logStep * (mel - minLogMel))
            }
        }
    }

    // Convert to mel scale and back
    let mMin = hzToMel(fMin)
    let mMax = hzToMel(fMaxVal)

    var mPts = [Float](repeating: 0, count: nMels + 2)
    for i in 0..<(nMels + 2) {
        mPts[i] = mMin + Float(i) * (mMax - mMin) / Float(nMels + 1)
    }

    let fPts = mPts.map { melToHz($0) }

    // Compute filterbank
    var filterbank = [[Float]](repeating: [Float](repeating: 0, count: nMels), count: nFreqs)

    for i in 0..<nFreqs {
        for j in 0..<nMels {
            let low = fPts[j]
            let center = fPts[j + 1]
            let high = fPts[j + 2]

            if allFreqs[i] >= low && allFreqs[i] < center {
                filterbank[i][j] = (allFreqs[i] - low) / (center - low)
            } else if allFreqs[i] >= center && allFreqs[i] <= high {
                filterbank[i][j] = (high - allFreqs[i]) / (high - center)
            }
        }
    }

    // Apply slaney normalization
    if norm == "slaney" {
        for j in 0..<nMels {
            let enorm = 2.0 / (fPts[j + 2] - fPts[j])
            for i in 0..<nFreqs {
                filterbank[i][j] *= enorm
            }
        }
    }

    // Convert to MLXArray [nFreqs, nMels]
    let flatFilters = filterbank.flatMap { $0 }
    return MLXArray(flatFilters).reshaped([nFreqs, nMels])
}
