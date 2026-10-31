// LoRASaver.swift - Save LoRA weights in ComfyUI/Diffusers format
// Copyright 2026

import Foundation
@preconcurrency import MLX
import MLXNN

/// Saves trained LoRA weights in PEFT/HuggingFace-compatible format.
///
/// Output format: `.safetensors` with keys like:
///   `diffusion_model.transformer_blocks.0.attn1.to_q.lora_A.weight`
///   `diffusion_model.transformer_blocks.0.attn1.to_q.lora_B.weight`
///
/// No per-layer alpha is saved — the scale (alpha/rank) is baked into the
/// weights during training, so the inference loader uses effectiveScale=1.0.
struct LoRASaver {

    /// Save LoRA weights from a model with injected LoRALinear layers.
    ///
    /// - Parameters:
    ///   - model: The model containing LoRALinear layers
    ///   - path: Output path for the .safetensors file
    ///   - rank: LoRA rank (for metadata)
    ///   - alpha: LoRA alpha (for metadata)
    /// - Returns: Number of layers saved
    @discardableResult
    static func save(
        model: Module,
        to path: String,
        rank: Int,
        alpha: Float
    ) throws -> Int {
        let loraWeights = LoRAInjector.extractLoRAWeights(from: model)

        guard !loraWeights.isEmpty else {
            throw TrainingError.checkpointError("No LoRA layers found in model")
        }

        // Build save dictionary with ComfyUI/Diffusers key format
        var saveDict: [String: MLXArray] = [:]

        // Scale factor baked into weights: the inference loader will use
        // effectiveScale=1.0 (no alpha key), so we pre-scale here.
        let loraScale = alpha / Float(rank)
        let scaleArray = MLXArray(loraScale)

        for (swiftPath, down, up) in loraWeights {
            let loraKey = LoRAKeyMapper.modelKeyToLoraKey(swiftPath)

            // Training uses mlx-examples convention: loraA=(inF, rank), loraB=(rank, outF)
            // PEFT format: lora_A=(rank, inF), lora_B=(outF, rank)
            // Transpose to match the inference loader's getDelta: matmul(B, A)
            // Bake scale into lora_B so effectiveScale=1.0 at inference
            saveDict["\(loraKey).lora_A.weight"] = down.transposed()
            saveDict["\(loraKey).lora_B.weight"] = (up * scaleArray).transposed()
        }

        // Save as safetensors
        let url = URL(fileURLWithPath: path)
        try MLX.save(arrays: saveDict, url: url)

        LTXDebug.log("LoRA saved: \(loraWeights.count) layers to \(path)")
        return loraWeights.count
    }

    /// Save a training checkpoint (LoRA weights + optimizer state metadata)
    ///
    /// - Parameters:
    ///   - model: Model with LoRA layers
    ///   - step: Current training step
    ///   - loss: Current loss value
    ///   - outputDir: Directory to save checkpoint
    ///   - rank: LoRA rank
    ///   - alpha: LoRA alpha
    static func saveCheckpoint(
        model: Module,
        step: Int,
        loss: Float,
        outputDir: String,
        rank: Int,
        alpha: Float
    ) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputDir) {
            try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        }

        // Save LoRA weights
        let filename = "checkpoint-step\(step).safetensors"
        let path = (outputDir as NSString).appendingPathComponent(filename)
        try save(model: model, to: path, rank: rank, alpha: alpha)

        // Save metadata
        let metadata: [String: Any] = [
            "step": step,
            "loss": loss,
            "rank": rank,
            "alpha": alpha,
        ]
        let metadataPath = (outputDir as NSString).appendingPathComponent("checkpoint-step\(step).json")
        let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try jsonData.write(to: URL(fileURLWithPath: metadataPath))
    }
}
