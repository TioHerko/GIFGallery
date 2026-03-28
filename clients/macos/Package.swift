// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GIFGallery",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GIFGallery",
            path: "Sources",
            exclude: ["Info.plist"]
        ),
    ]
)
