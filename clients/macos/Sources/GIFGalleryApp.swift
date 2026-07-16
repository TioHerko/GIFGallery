import GIFKit
import SwiftUI

@main
struct GIFGalleryApp: App {
    static let viewModel = GalleryViewModel()

    init() {
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
