// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotoCraftKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PhotoCraftKit", targets: ["PhotoCraftKit"]),
    ],
    targets: [
        .target(name: "PhotoCraftKit"),
        .testTarget(
            name: "PhotoCraftKitTests",
            dependencies: ["PhotoCraftKit"],
            resources: [.copy("Golden")]
        ),
    ]
)
