// swift-tools-version: 5.9
//
// z-image-swift — Swift/MLX port of Tongyi Z-Image (Apache-2.0). Local copy for NVAI-open (see
// NVAI-OPEN-CHANGES.md): the ZImage core only, without mlx-swift-lm, mlx-exact-conv-swift and mlx-profiling;
// mlx-swift and swift-transformers resolve to the versions flux-2-swift-mlx pins.
import PackageDescription

let package = Package(
    name: "ZImage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZImage", targets: ["ZImage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", "0.30.0" ..< "0.32.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
    ],
    targets: [
        .target(
            name: "ZImage",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/ZImage"
        ),
    ]
)
