// swift-tools-version: 5.9
//
// seedvr2-mlx-swift — standalone MLX-Swift port of SeedVR2 (ByteDance) one-step diffusion super-resolution.
// Local copy for NVAI-open (see NVAI-OPEN-CHANGES.md): library target only; mlx-swift resolves to the exact pin of
// flux-2-swift-mlx (0.31.6), which lies inside this range.
import PackageDescription

let package = Package(
    name: "SeedVR2MLX",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "SeedVR2MLX", targets: ["SeedVR2MLX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", "0.31.2" ..< "0.32.0"),
    ],
    targets: [
        .target(
            name: "SeedVR2MLX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            path: "Sources/SeedVR2MLX"
        ),
    ]
)
