// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GIFGallery",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../GIFKit"),
    ],
    targets: [
        .executableTarget(
            name: "GIFGallery",
            dependencies: [
                .product(name: "GIFKit", package: "GIFKit"),
            ],
            path: "Sources",
            exclude: ["Info.plist"]
        ),
    ]
)
