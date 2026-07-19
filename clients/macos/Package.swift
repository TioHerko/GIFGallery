// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GIFGallery",
    platforms: [.macOS(.v15)],
    products: [
        // Emitted as a dylib that build.sh renames into the executable of
        // GIF Lobster Dock.docktileplugin (NSBundle loads dylibs fine).
        .library(name: "DockTilePlugin", type: .dynamic, targets: ["DockTilePlugin"]),
    ],
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
        // Dock tile plug-in: draws the raw app icon so the Dock doesn't force
        // it into a squircle. Assembled into Contents/PlugIns/ by build.sh.
        .target(
            name: "DockTilePlugin",
            path: "DockTilePlugin/Sources"
        ),
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
