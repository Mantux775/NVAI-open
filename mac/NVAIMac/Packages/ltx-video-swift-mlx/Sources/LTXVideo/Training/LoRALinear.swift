// LoRALinear.swift - Trainable LoRA layer extending Linear
// Copyright 2026

import Foundation
@preconcurrency import MLX
import MLXNN

/// A trainable LoRA layer that extends Linear.
///
/// Forward: `base(x) + scale * matmul(matmul(x, loraA), loraB)`
///
/// Only `loraA` and `loraB` appear in `trainableParameters()`.
///
/// Works with both `Linear` and `QuantizedLinear` bases by capturing the
/// original module's forward pass as a closure (invisible to MLX Module tree).
///
/// Shapes follow the mlx-examples convention (no transposes needed):
/// - `loraA`: `(inFeatures, rank)`
/// - `loraB`: `(rank, outFeatures)`
/// - `scale = alpha / rank`
class LoRALinear: Linear {
    /// LoRA down projection: (inFeatures, rank)
    var loraA: MLXArray

    /// LoRA up projection: (rank, outFeatures)
    var loraB: MLXArray

    /// Scaling factor: alpha / rank
    let loraScale: Float

    /// LoRA rank
    let rank: Int

    /// Alpha value
    let alpha: Float

    /// Captured forward from the original base module.
    /// Using a closure (not a Module property) prevents MLX Module reflection
    /// from discovering the base as a child, avoiding aliased parameter trees.
    private let _baseForward: (MLXArray) -> MLXArray

    init(base: Linear, rank: Int = 16, alpha: Float? = nil) {
        self.rank = rank
        self.alpha = alpha ?? Float(rank)
        self.loraScale = self.alpha / Float(rank)

        // Get actual input dimensions (handles QuantizedLinear packed weights)
        let (outFeatures, inFeatures) = base.shape

        // Initialize LoRA matrices (mlx-examples convention: no transposes)
        let bound = Float(1.0 / Double(inFeatures).squareRoot())
        self.loraA = MLXRandom.uniform(
            low: -bound, high: bound,
            [inFeatures, rank]
        ).asType(.float32)
        self.loraB = MLXArray.zeros([rank, outFeatures]).asType(.float32)

        // Capture the base forward as a closure — invisible to MLX Module tree
        // This correctly delegates to QuantizedLinear.callAsFunction for quantized models
        self._baseForward = { x in base.callAsFunction(x) }

        // Initialize with a dummy weight — we never use self.weight in forward.
        // This avoids aliasing self.weight with the quantized base weight.
        super.init(weight: MLXArray.zeros([1, 1]), bias: nil)

        // Freeze dummy weight so only loraA/loraB are trainable
        self.freeze(recursive: false, keys: ["weight", "bias"])
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        // Base forward: delegates to original Linear or QuantizedLinear via closure
        let baseOutput = _baseForward(x)

        // LoRA delta: scale * matmul(matmul(x, A), B)
        let xFloat = x.asType(.float32)
        let loraOut = MLX.matmul(MLX.matmul(xFloat, loraA), loraB) * loraScale

        return baseOutput + loraOut.asType(baseOutput.dtype)
    }
}
