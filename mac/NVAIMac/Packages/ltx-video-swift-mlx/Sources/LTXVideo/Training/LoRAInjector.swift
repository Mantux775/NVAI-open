// LoRAInjector.swift - Inject LoRA layers into a frozen transformer
// Copyright 2026

import Foundation
@preconcurrency import MLX
import MLXNN

/// Injects trainable LoRA layers into a frozen transformer model.
///
/// Uses the same pattern as MLX's `quantize()`: walks `leafModules().flattened()`,
/// creates replacement modules, and applies them via `model.update(modules:)`.
///
/// After injection, only `loraA` and `loraB` parameters are trainable.
///
/// Target layers (matching ostris `LTX2VideoTransformer3DModel`):
/// - `attn1.to_q/k/v/to_out` (self-attention video)
/// - `attn2.to_q/k/v/to_out` (cross-attention)
/// - `ff.project_in.proj`, `ff.project_out` (FFN)
/// - Audio: `audio_attn*`, `audio_ff*`, `audio_to_video_attn`, `video_to_audio_attn`
struct LoRAInjector {

    /// Result of LoRA injection
    struct InjectionResult {
        /// Number of Linear layers replaced with LoRALinear
        let injectedCount: Int
        /// Paths of injected layers
        let injectedPaths: [String]
    }

    /// Inject LoRA layers into a transformer model.
    ///
    /// Process:
    /// 1. Freeze all model parameters
    /// 2. Find all matching Linear leaf modules
    /// 3. Replace them with LoRALinear wrappers
    /// 4. Only loraA/loraB are trainable after injection
    /// 5. If lastNBlocks > 0, freeze LoRA in early blocks (only last N are trainable)
    ///
    /// - Parameters:
    ///   - model: The transformer model to inject into
    ///   - rank: LoRA rank (default: 16)
    ///   - alpha: LoRA alpha (default: same as rank)
    ///   - includeAudio: Whether to target audio layers too
    ///   - includeFFN: Whether to target FFN layers
    ///   - lastNBlocks: Only train LoRA in the last N transformer blocks (0 = all blocks).
    ///     LoRA is injected into all blocks for structural compatibility, but early blocks
    ///     are frozen. Combined with `stopGradient` in the transformer, this prevents
    ///     backward from tracing through frozen blocks, saving memory.
    /// - Returns: Injection result with count and paths
    @discardableResult
    static func inject(
        into model: Module,
        rank: Int = 16,
        alpha: Float? = nil,
        includeAudio: Bool = false,
        includeFFN: Bool = true,
        lastNBlocks: Int = 0
    ) -> InjectionResult {
        // Step 1: Freeze the entire model
        model.freeze()

        // Step 2: Find and replace Linear modules (same pattern as MLX quantize())
        let updates = model.leafModules().flattened().compactMap { (path, module) -> (String, Module)? in
            guard let linear = module as? Linear else { return nil }
            guard shouldTarget(path: path, includeAudio: includeAudio, includeFFN: includeFFN) else {
                return nil
            }
            let loraLinear = LoRALinear(base: linear, rank: rank, alpha: alpha)
            return (path, loraLinear)
        }

        // Step 3: Apply replacements
        if !updates.isEmpty {
            model.update(modules: ModuleChildren.unflattened(updates))
        }

        let injectedPaths = updates.map { $0.0 }

        // Step 4: Freeze LoRA in early blocks (selective training)
        var frozenLoRACount = 0
        if lastNBlocks > 0 {
            var totalBlocks = 0
            for path in injectedPaths {
                if let idx = extractBlockIndex(from: path), idx + 1 > totalBlocks {
                    totalBlocks = idx + 1
                }
            }
            let firstTrainableBlock = totalBlocks - min(lastNBlocks, totalBlocks)
            for (path, module) in model.leafModules().flattened() {
                if let lora = module as? LoRALinear,
                   let idx = extractBlockIndex(from: path),
                   idx < firstTrainableBlock {
                    lora.freeze()
                    frozenLoRACount += 1
                }
            }
            LTXDebug.log("LoRA selective: \(injectedPaths.count) total, \(frozenLoRACount) frozen (blocks 0..<\(firstTrainableBlock)), \(injectedPaths.count - frozenLoRACount) trainable (blocks \(firstTrainableBlock)..<\(totalBlocks))")
        }

        // Step 5: Verify — only LoRA parameters should be trainable
        let trainableCount = model.trainableParameters().flattenedValues().count
        LTXDebug.log("LoRA injected: \(injectedPaths.count) layers, \(trainableCount) trainable parameter tensors")

        return InjectionResult(
            injectedCount: injectedPaths.count,
            injectedPaths: injectedPaths
        )
    }

    /// Extract LoRA weights from an injected model for saving.
    ///
    /// Returns a dictionary mapping layer paths to (loraA, loraB) pairs.
    static func extractLoRAWeights(from model: Module) -> [(path: String, down: MLXArray, up: MLXArray)] {
        var results: [(path: String, down: MLXArray, up: MLXArray)] = []

        for (path, module) in model.leafModules().flattened() {
            if let loraLinear = module as? LoRALinear {
                results.append((path: path, down: loraLinear.loraA, up: loraLinear.loraB))
            }
        }

        return results
    }

    /// Load saved LoRA weights (PEFT format) back into injected LoRALinear layers.
    ///
    /// Used for resuming training from a checkpoint. The checkpoint stores weights
    /// in PEFT format (lora_A/lora_B, transposed). This reverses the transpose
    /// and loads them into the matching LoRALinear layers.
    ///
    /// - Parameters:
    ///   - weights: Dictionary of weight arrays from the checkpoint safetensors file
    ///   - model: The model with injected LoRALinear layers
    ///   - rank: Expected LoRA rank (for validation)
    static func loadLoRAWeights(_ weights: [String: MLXArray], into model: Module, rank: Int) throws {
        var loadedCount = 0

        for (path, module) in model.leafModules().flattened() {
            guard let loraLinear = module as? LoRALinear else { continue }

            let loraKey = LoRAKeyMapper.modelKeyToLoraKey(path)
            let aKey = "\(loraKey).lora_A.weight"
            let bKey = "\(loraKey).lora_B.weight"

            guard let savedA = weights[aKey], let savedB = weights[bKey] else {
                continue
            }

            // Reverse the transpose from save: PEFT (rank, inF) → mlx-examples (inF, rank)
            loraLinear.loraA = savedA.transposed().asType(.float32)
            // lora_B has scale baked in. Reverse transpose: PEFT (outF, rank) → (rank, outF)
            // Also remove the baked scale so training continues correctly
            let scale = loraLinear.loraScale
            if scale != 0 {
                loraLinear.loraB = (savedB.transposed() / MLXArray(scale)).asType(.float32)
            } else {
                loraLinear.loraB = savedB.transposed().asType(.float32)
            }
            loadedCount += 1
        }

        eval(model.trainableParameters())
        LTXDebug.log("Loaded \(loadedCount) LoRA layers from checkpoint")
    }

    // MARK: - Private

    /// Extract the last dot-separated component from a module path
    private static func lastDotComponent(_ path: String) -> String {
        if let lastDot = path.lastIndex(of: ".") {
            return String(path[path.index(after: lastDot)...])
        }
        return path
    }

    /// Extract the transformer block index from a module path
    /// e.g. "transformer_blocks.42.attn1.to_q" → 42
    private static func extractBlockIndex(from path: String) -> Int? {
        guard let range = path.range(of: "transformer_blocks.") else { return nil }
        let afterPrefix = path[range.upperBound...]
        guard let dotIdx = afterPrefix.firstIndex(of: ".") else { return nil }
        return Int(afterPrefix[..<dotIdx])
    }

    /// Check if a module path should be targeted for LoRA injection
    private static func shouldTarget(path: String, includeAudio: Bool, includeFFN: Bool) -> Bool {
        // Must be inside a transformer block
        guard path.contains("transformer_blocks") else { return false }

        let last = lastDotComponent(path)

        // Attention projections (video)
        if path.contains("attn1.") || path.contains("attn2.") {
            if ["to_q", "to_k", "to_v", "to_out"].contains(last) {
                return true
            }
        }

        // FFN projections (video)
        if includeFFN {
            if path.contains(".ff.project_in.") && last == "proj" {
                return true
            }
            if last == "project_out" && path.contains(".ff.") {
                return true
            }
        }

        // Audio targets
        if includeAudio {
            // Audio attention
            if path.contains("audio_attn1.") || path.contains("audio_attn2.") {
                if ["to_q", "to_k", "to_v", "to_out"].contains(last) {
                    return true
                }
            }
            // Audio FFN
            if includeFFN {
                if path.contains(".audio_ff.project_in.") && last == "proj" {
                    return true
                }
                if last == "project_out" && path.contains(".audio_ff.") {
                    return true
                }
            }
            // Cross-modal attention (audio ↔ video)
            if path.contains("audio_to_video_attn.") || path.contains("video_to_audio_attn.") {
                if ["to_q", "to_k", "to_v", "to_out"].contains(last) {
                    return true
                }
            }
        }

        return false
    }
}
