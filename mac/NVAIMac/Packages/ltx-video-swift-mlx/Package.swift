// swift-tools-version: 6.0
// Lokale Kopie von VincentGourbin/ltx-video-swift-mlx v0.4.2 (MIT) für NVAI-open: nur die Bibliothek, mlx-swift
// exakt wie FLUX.2 und mlx-swift-lm auf der Fassung der App statt "main" (siehe NVAI-OPEN-CHANGES.md).

import PackageDescription

let package = Package(
    name: "ltx-video-swift-mlx",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "LTXVideo", targets: ["LTXVideo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", "3.31.4" ..< "3.32.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/VincentGourbin/swift-mlx-profiler", from: "1.4.0"),
        // LTX-2.5 encodes prompts with `gemma4-12b-ltx-v1`, a gemma4_unified derivative.
        .package(url: "https://github.com/VincentGourbin/gemma-4-swift-mlx", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "LTXVideo",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
                .product(name: "MLXProfiler", package: "swift-mlx-profiler"),
                .product(name: "Gemma4Swift", package: "gemma-4-swift-mlx"),
            ]
        ),
    ]
)
