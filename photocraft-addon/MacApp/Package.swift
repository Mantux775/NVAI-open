// swift-tools-version:5.9
import PackageDescription

// Mac-App „NVAI-open für PhotoCraft“: das Panel der Windows-Brücke als native App auf PhotoCraftKit.
// Bauen und auf den Schreibtisch legen: ./build-app.sh (auf dem Mac).
let package = Package(
    name: "NVAIPhotoCraft",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../PhotoCraftKit")],
    targets: [
        .executableTarget(
            name: "NVAIPhotoCraft",
            dependencies: [.product(name: "PhotoCraftKit", package: "PhotoCraftKit")],
            path: "Sources/NVAIPhotoCraft"
        ),
    ]
)
