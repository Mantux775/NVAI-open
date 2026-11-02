// swift-tools-version: 5.9
//
// Qwen3-TTS (12 Hz: VoiceDesign, Base clone, CustomVoice) on MLX for NVAI-open, taken from
// Blaizzy/mlx-audio-swift (MIT). See NVAI-OPEN-CHANGES.md. mlx-swift is pinned exactly like
// flux-2-swift-mlx (0.31.6), mlx-swift-lm and swift-transformers resolve to the app's versions.
import PackageDescription

let package = Package(
    name: "qwen3-tts-swift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Qwen3TTSKit", targets: ["Qwen3TTSKit"]),
        .executable(name: "qwen3tts-check", targets: ["qwen3tts-check"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", "3.31.4" ..< "3.32.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", "1.3.5" ..< "2.0.0"),
    ],
    targets: [
        // Speech-tokenizer encoder parts (SEANet, transformer, RVQ) from mlx-audio-swift's Mimi codec.
        .target(
            name: "Qwen3TTSMimi",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/Qwen3TTSMimi"
        ),
        .target(
            name: "Qwen3TTSKit",
            dependencies: [
                "Qwen3TTSMimi",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/Qwen3TTSKit"
        ),
        // Command-line check on the Mac (load, generate, WAV out, timing, memory).
        .executableTarget(
            name: "qwen3tts-check",
            dependencies: [
                "Qwen3TTSKit",
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/qwen3tts-check"
        ),
    ]
)
