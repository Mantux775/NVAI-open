// swift-tools-version: 5.9
//
// ltxv-swift — LTX-Video 2B (0.9.x, distilled) in Swift/MLX for NVAI-open: the T5-XXL text encoder, the LTX video
// transformer and the video VAE decoder. Written for NVAI-open after Lightricks/LTX-Video (Apache-2.0); see README.md.
import PackageDescription

let package = Package(
    name: "LTXV",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LTXV", targets: ["LTXV"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", "0.30.0" ..< "0.32.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
    ],
    targets: [
        .target(
            name: "LTXV",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/LTXV"
        ),
    ]
)
