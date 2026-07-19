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
