// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GIFKit",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "GIFKit", targets: ["GIFKit"]),
    ],
    targets: [
        .target(
            name: "GIFKit",
            path: "Sources/GIFKit"
        ),
        .testTarget(
            name: "GIFKitTests",
            dependencies: ["GIFKit"],
            path: "Tests/GIFKitTests"
        ),
    ]
)
