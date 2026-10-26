// swift-tools-version: 5.9
//
// Stable Audio 3 (Medium) on MLX, taken from soniqo/speech-swift (Apache-2.0) for NVAI-open.
// See NVAI-OPEN-CHANGES.md. mlx-swift resolves to the exact pin of flux-2-swift-mlx (0.31.6).
import PackageDescription

let package = Package(
    name: "StableAudio3",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StableAudio3", targets: ["StableAudio3"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", "0.30.0" ..< "0.32.0"),
    ],
    targets: [
        .target(
            name: "StableAudio3",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            path: "Sources/StableAudio3"
        ),
    ]
)
