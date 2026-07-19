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
        // The share extension binary. App extensions have no main() of their
        // own — the system calls into NSExtensionMain — so the entry point is
        // overridden at link time. build.sh assembles this into
        // Contents/PlugIns/GIF Lobster Share.appex.
        .executableTarget(
            name: "ShareExtension",
            dependencies: [
                .product(name: "GIFKit", package: "GIFKit"),
            ],
            path: "ShareExtension/Sources",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
    ]
)
