import GIFKit
import SwiftUI

@main
struct GIFGalleryApp: App {
    static let viewModel = GalleryViewModel()

    init() {
        SharedStore.configure()
        // Triggers the one-time migration of a token saved by pre-extension
        // builds into the shared keychain group.
        _ = KeychainStore.loadToken()
        APIClient.installPersistentCache()
    }

    var body: some Scene {
        WindowGroup {
            GalleryView(viewModel: Self.viewModel)
        }
    }
}
