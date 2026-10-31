// BigVGANWeightLoader.swift - Loading the checkpoint's vocoder + BWE weights
// Copyright 2025

import Foundation
@preconcurrency import MLX
import MLXNN

/// Loads `vocoder.*` out of an LTX audio-VAE bundle into ``LTXVocoderWithBWE``.
///
/// The bundle nests three trees under one prefix — `vocoder.vocoder.*` (the base
/// generator), `vocoder.bwe_generator.*` and `vocoder.mel_stft.*` — which map
/// one-for-one onto the Swift module tree once the torch conv layouts are
/// transposed.
enum BigVGANWeightLoader {

    /// Read and apply every vocoder weight in `url`.
    ///
    /// - Throws: when the file carries no BigVGAN vocoder (an LTX-2-era
    ///   standalone vocoder file, for instance), or when any declared parameter
    ///   goes unfed — a partially-loaded vocoder emits plausible noise rather
    ///   than failing.
    static func load(from url: URL) throws -> LTXVocoderWithBWE {
        let raw = try MLX.loadArrays(url: url)
        let prefix = "vocoder."

        var mapped: [String: MLXArray] = [:]
        for (key, value) in raw where key.hasPrefix(prefix) {
            let path = String(key.dropFirst(prefix.count))
            mapped[path] = transpose(value, forPath: path)
        }
        guard mapped.keys.contains(where: { $0.hasPrefix("bwe_generator.") }) else {
            throw LTXError.weightLoadingFailed(
                "\(url.lastPathComponent) has no bandwidth-extension generator — this is an "
                + "LTX-2-era vocoder, not the one LTX-2.3+ checkpoints ship.")
        }

        let model = LTXVocoderWithBWE()
        let declared = Dictionary(uniqueKeysWithValues: model.parameters().flattened())

        var updates: [String: MLXArray] = [:]
        var unmatched: [String] = []
        for (key, value) in mapped {
            guard let target = declared[key] else { unmatched.append(key); continue }
            guard target.shape == value.shape else {
                throw LTXError.weightLoadingFailed(
                    "Vocoder \(key): checkpoint \(value.shape) vs model \(target.shape)")
            }
            updates[key] = value
        }

        // The BWE skip resampler's kernel is derived, not loaded: upstream registers
        // it with `persistent=False`, so no checkpoint carries it. Named explicitly
        // rather than tolerated by pattern, so a genuinely missing filter still fails.
        let derived: Set<String> = ["resampler.filter"]
        let unfed = Set(declared.keys).subtracting(updates.keys).subtracting(derived).sorted()
        guard unfed.isEmpty else {
            throw LTXError.weightLoadingFailed(
                "Vocoder: \(unfed.count) parameters unfed "
                + "(\(unfed.prefix(5).joined(separator: ", "))\(unfed.count > 5 ? ", …" : ""))")
        }
        if !unmatched.isEmpty {
            LTXDebug.log("[Vocoder] \(unmatched.count) checkpoint keys unused: "
                + unmatched.sorted().prefix(5).joined(separator: ", "))
        }

        // The reference forces float32 for this entire stage — its own docstring:
        // bf16 accumulation across ~108 sequential convolutions degrades spectral
        // metrics 40-90%. Casting only the runtime input (as callAsFunction did)
        // still leaves every conv weight at the checkpoint's native bf16, so the
        // convolutions themselves keep accumulating at reduced precision.
        for key in updates.keys { updates[key] = updates[key]!.asType(.float32) }
        model.update(parameters: ModuleParameters.unflattened(updates))
        eval(model.parameters())
        LTXDebug.log("[Vocoder] applied \(updates.count) BigVGAN weights")
        return model
    }

    /// Torch stores convolutions channels-first; MLX wants the kernel in the middle.
    ///
    /// Four cases, keyed off the module path rather than guessed from rank —
    /// every rank-3 tensor here would otherwise look alike:
    /// - `ups.*`: transposed convolutions, `(in, out, K)` → `(out, K, in)`
    /// - `*_basis`: DFT bases used as a convolution, `(rows, 1, K)` → `(rows, K, 1)`
    /// - `*.filter`: the resampling kernels, kept in torch's `[1, 1, K]` layout
    ///   because they are broadcast per channel at call time, not used directly
    /// - everything else: ordinary convolutions, `(out, in, K)` → `(out, K, in)`
    private static func transpose(_ value: MLXArray, forPath path: String) -> MLXArray {
        guard value.ndim == 3 else { return value }
        if path.hasSuffix(".filter") { return value }
        if path.contains(".ups.") || path.hasPrefix("ups.") {
            return value.transposed(1, 2, 0)
        }
        return value.transposed(0, 2, 1)
    }
}
