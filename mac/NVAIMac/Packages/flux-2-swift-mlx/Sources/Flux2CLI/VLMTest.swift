// VLMTest.swift - Direct VLM test without text model loading
// This is a simple test to verify VLM works when loaded directly

import Foundation
import ArgumentParser
import FluxTextEncoders

struct VLMTest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vlm-test",
        abstract: "Test VLM directly without text encoder (debug tool)"
    )

    @Argument(help: "Image path")
    var imagePath: String

    @Argument(help: "Prompt for VLM")
    var prompt: String

    @MainActor
    func run() async throws {
        print("VLM Direct Test (no text encoder loaded first)")
        print("Image: \(imagePath)")
        print("Prompt: \(prompt)")
        print()

        // Verify image exists
        guard FileManager.default.fileExists(atPath: imagePath) else {
            print("Error: Image not found: \(imagePath)")
            throw ExitCode.failure
        }

        // Check initial state
        print("[TEST] Initial state:")
        print("  isModelLoaded: \(FluxTextEncoders.shared.isModelLoaded)")
        print("  isVLMLoaded: \(FluxTextEncoders.shared.isVLMLoaded)")
        print()

        // Load VLM directly (without loading text model first)
        print("[TEST] Loading VLM directly...")
        try await FluxTextEncoders.shared.loadVLMModel(variant: .mlx4bit) { progress, message in
            print("  \(message) (\(Int(progress * 100))%)")
        }
        print("[TEST] VLM loaded!")
        print()

        // Check state after VLM load
        print("[TEST] State after VLM load:")
        print("  isModelLoaded: \(FluxTextEncoders.shared.isModelLoaded)")
        print("  isVLMLoaded: \(FluxTextEncoders.shared.isVLMLoaded)")
        print()

        // Call analyzeImage with I2I upsampling system prompt
        print("[TEST] Calling analyzeImage with I2I system prompt...")
        print()

        // Use EXACT same parameter construction as FluxEncodersCLI (no explicit repetitionContextSize)
        let params = GenerateParameters(
            maxTokens: 2048,
            temperature: 0.7,
            topP: 0.95,
            repetitionPenalty: 1.1
        )
        print("[TEST] Parameters: maxTokens=\(params.maxTokens), temp=\(params.temperature), topP=\(params.topP), repPenalty=\(params.repetitionPenalty), repContextSize=\(params.repetitionContextSize)")
        print()

        let result = try FluxTextEncoders.shared.analyzeImage(
            path: imagePath,
            prompt: prompt,
            systemPrompt: FluxConfig.systemMessage(for: .upsamplingI2I),
            parameters: params
        ) { token in
            return true
        }

        print("[TEST] Result:")
        print(result.text)
        print()
        print("[TEST] Stats:")
        print(result.summary())
    }
}
