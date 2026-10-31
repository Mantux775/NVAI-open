// AncestralEulerStep.swift - Ancestral (SDE) Euler step for rectified flow
// Copyright 2026

import Foundation
@preconcurrency import MLX

/// Ancestral Euler step, the sampler the temporal refinement rounds use.
///
/// A plain Euler step walks straight to `sigmaNext`. The ancestral variant
/// walks *past* it to an intermediate `sigmaDown`, then adds fresh noise back up
/// to `sigmaNext`. The re-injected randomness is what lets a refinement pass
/// invent plausible in-between motion rather than smoothly interpolating what
/// it already has — which is precisely what doubling a frame rate needs.
///
/// This is the rectified-flow parameterisation (`alpha = 1 - sigma`), matching
/// LTX-2: the signal component is rescaled by `alphaNext / alphaDown` so the
/// transition stays variance-preserving. It deliberately differs from the
/// DDIM/variance-exploding ancestral coefficients, which give a different
/// `sigmaDown` and a different noise amount for the same `eta`; the two agree
/// only at `eta = 0`.
///
/// - `eta = 0` degenerates to a plain Euler step (no noise, `sigmaDown` =
///   `sigmaNext`), so one implementation covers both.
/// - `eta = 0.5` is what upstream's temporal rounds use.
public struct AncestralEulerStep: Sendable {
    /// How ancestral the step is: 0 = deterministic Euler, 1 = fully ancestral.
    public let eta: Float
    /// Scales the re-injected noise; 1.0 unless a caller wants it damped.
    public let sNoise: Float

    public init(eta: Float = 1.0, sNoise: Float = 1.0) {
        self.eta = eta
        self.sNoise = sNoise
    }

    /// Advance one step.
    ///
    /// - Parameters:
    ///   - sample: current noisy latent `x_t`
    ///   - denoised: the model's `x₀` prediction
    ///   - sigma: noise level now
    ///   - sigmaNext: noise level after this step
    ///   - noise: standard normal, same shape as `sample`. Required when
    ///     `eta > 0`; ignored otherwise.
    /// - Returns: `x_{t-1}`, or the denoised prediction when `sigmaNext` is 0.
    public func callAsFunction(
        sample: MLXArray,
        denoised: MLXArray,
        sigma: Float,
        sigmaNext: Float,
        noise: MLXArray? = nil
    ) -> MLXArray {
        guard sigmaNext != 0 else { return denoised.asType(sample.dtype) }

        let x = sample.asType(.float32)
        let x0 = denoised.asType(.float32)

        let downstepRatio = 1.0 + (sigmaNext / sigma - 1.0) * eta
        let sigmaDown = sigmaNext * downstepRatio

        // Euler to sigmaDown, written as an interpolation between x and x₀.
        let ratio = sigmaDown / sigma
        var next = MLXArray(ratio) * x + MLXArray(1.0 - ratio) * x0

        if eta > 0 {
            guard let noise else {
                // Degrade to the deterministic step rather than fabricating
                // noise: a silent fallback here would be indistinguishable
                // from a working ancestral sampler.
                LTXDebug.log("[ancestral] eta \(eta) but no noise supplied — stepping deterministically")
                return next.asType(sample.dtype)
            }
            let alphaNext = 1.0 - sigmaNext
            let alphaDown = 1.0 - sigmaDown
            let variance = sigmaNext * sigmaNext
                - sigmaDown * sigmaDown * alphaNext * alphaNext / (alphaDown * alphaDown)
            let renoise = sqrt(max(0, variance))
            next = MLXArray(alphaNext / alphaDown) * next
                + noise.asType(.float32) * MLXArray(sNoise * renoise)
        }
        return next.asType(sample.dtype)
    }
}
