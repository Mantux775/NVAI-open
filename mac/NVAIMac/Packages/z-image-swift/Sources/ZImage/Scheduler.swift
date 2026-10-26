// FlowMatchEulerDiscreteScheduler — isomorphic port of zimage-oracle
// src/zimage/scheduler.py (itself modified from diffusers). Pure fp32 math.
//
// Checkpoint configs (both `use_dynamic_shifting: false`): Turbo shift 3.0, Base
// shift 6.0. The dynamic `timeShift` path is ported anyway — config-driven, never
// hardcode the static assumption (PORTING-SPEC "checkpoint-config ground truth").

import Foundation
import MLX

public struct SchedulerOutput {
    public let prevSample: MLXArray
}

public final class FlowMatchEulerDiscreteScheduler {

    public let numTrainTimesteps: Int
    public let shift: Float
    public let useDynamicShifting: Bool

    public private(set) var timesteps: [Float]
    public private(set) var sigmas: [Float]
    public var sigmaMin: Float
    public var sigmaMax: Float
    public private(set) var numInferenceSteps: Int?

    private var _stepIndex: Int?
    private var _beginIndex: Int?

    public var stepIndex: Int? { _stepIndex }

    public init(
        numTrainTimesteps: Int = 1000,
        shift: Float = 1.0,
        useDynamicShifting: Bool = false
    ) {
        self.numTrainTimesteps = numTrainTimesteps
        self.shift = shift
        self.useDynamicShifting = useDynamicShifting

        // timesteps = linspace(1, N, N)[::-1]; sigmas = timesteps / N
        var sigmas: [Float] = (0..<numTrainTimesteps).map { i in
            let t = 1.0 + Double(i) * (Double(numTrainTimesteps) - 1.0) / Double(numTrainTimesteps - 1)
            return Float(t) / Float(numTrainTimesteps)
        }.reversed()

        if !useDynamicShifting {
            sigmas = sigmas.map { shift * $0 / (1 + (shift - 1) * $0) }
        }

        self.timesteps = sigmas.map { $0 * Float(numTrainTimesteps) }
        self.sigmas = sigmas
        self.sigmaMin = sigmas.last!
        self.sigmaMax = sigmas.first!
        self._stepIndex = nil
        self._beginIndex = nil
    }

    public func setTimesteps(
        numInferenceSteps: Int? = nil,
        sigmas passedSigmas: [Float]? = nil,
        mu: Float? = nil,
        timesteps passedTimesteps: [Float]? = nil
    ) {
        let steps: Int
        if let numInferenceSteps {
            steps = numInferenceSteps
        } else {
            steps = passedSigmas?.count ?? passedTimesteps!.count
        }
        self.numInferenceSteps = steps

        var timesteps: [Float]
        var sigmas: [Float]
        if let passedSigmas {
            sigmas = passedSigmas
            timesteps = passedTimesteps ?? []
        } else {
            if let passedTimesteps {
                timesteps = passedTimesteps
            } else {
                // linspace(sigma_to_t(sigma_max), sigma_to_t(sigma_min), steps + 1)[:-1]
                let hi = Double(sigmaToT(sigmaMax))
                let lo = Double(sigmaToT(sigmaMin))
                timesteps = (0..<steps).map { i in
                    Float(hi + Double(i) * (lo - hi) / Double(steps))
                }
            }
            sigmas = timesteps.map { $0 / Float(numTrainTimesteps) }
        }

        if useDynamicShifting {
            precondition(mu != nil, "mu required when use_dynamic_shifting is enabled")
            sigmas = sigmas.map { timeShift(mu: mu!, sigma: 1.0, t: $0) }
        } else {
            sigmas = sigmas.map { shift * $0 / (1 + (shift - 1) * $0) }
        }

        if passedTimesteps == nil {
            timesteps = sigmas.map { $0 * Float(numTrainTimesteps) }
        }

        sigmas.append(0.0)

        self.timesteps = timesteps
        self.sigmas = sigmas
        self._stepIndex = nil
        self._beginIndex = nil
    }

    public func indexForTimestep(_ timestep: Float, scheduleTimesteps: [Float]? = nil) -> Int {
        let schedule = scheduleTimesteps ?? timesteps
        let indices = schedule.enumerated().filter { $0.element == timestep }.map(\.offset)
        // Reference: pos = 1 if len(indices) > 1 else 0 (skip a duplicated first step).
        let pos = indices.count > 1 ? 1 : 0
        return indices[pos]
    }

    private func initStepIndex(_ timestep: Float) {
        if let _beginIndex {
            _stepIndex = _beginIndex
        } else {
            _stepIndex = indexForTimestep(timestep)
        }
    }

    /// Predict the sample at the previous timestep. fp32 in, fp32 out
    /// (reference asserts latents stay float32 through the loop).
    public func step(
        modelOutput: MLXArray,
        timestep: Float,
        sample: MLXArray
    ) -> SchedulerOutput {
        if _stepIndex == nil {
            initStepIndex(timestep)
        }
        let sample32 = sample.asType(.float32)
        let sigma = sigmas[_stepIndex!]
        let sigmaNext = sigmas[_stepIndex! + 1]
        let dt = sigmaNext - sigma
        let prev = sample32 + dt * modelOutput.asType(.float32)
        _stepIndex! += 1
        return SchedulerOutput(prevSample: prev)
    }

    func sigmaToT(_ sigma: Float) -> Float {
        sigma * Float(numTrainTimesteps)
    }

    func timeShift(mu: Float, sigma: Float, t: Float) -> Float {
        let em = exp(Double(mu))
        return Float(em / (em + pow(1.0 / Double(t) - 1.0, Double(sigma))))
    }
}
