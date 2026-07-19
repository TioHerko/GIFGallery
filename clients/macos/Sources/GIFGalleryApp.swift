import AppKit
import GIFKit
import SwiftUI

@main
struct GIFGalleryApp: App {
    static let viewModel = GalleryViewModel()

    init() {
        // Derives the app-group/keychain sharing config from the code
        // signature (no-op in unsigned dev builds).
        SharedStore.configure()
        APIClient.installPersistentCache()
        // The dock tile plug-in only covers the tile while the app is NOT
        // running; install the same raw (un-squircled) icon for the running
        // case. Deferred so NSApp exists.
        DispatchQueue.main.async { Self.installDockIcon() }
    }

    /// Draws the raw icon into the Dock tile, escaping the system's
    /// squircle treatment. The image lives in the dock tile plug-in bundle
    /// so it's shipped only once.
    @MainActor
    private static func installDockIcon() {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(
            "GIF Lobster Dock.docktileplugin/Contents/Resources/DockIcon.png"),
            let image = NSImage(contentsOf: url)
        else { return }
        let tile = NSApplication.shared.dockTile
        let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        view.image = image
        tile.contentView = view
        tile.display()
    }

    var body: some Scene {
        WindowGroup {
            GalleryView(viewModel: Self.viewModel)
                .frame(minWidth: 600, minHeight: 400)
        }

        Settings {
            SettingsView()
        }
    }
}
