// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GIFGallery",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "GIFGallery",
            path: "Sources",
            exclude: ["Info.plist"]
        ),
    ]
)
