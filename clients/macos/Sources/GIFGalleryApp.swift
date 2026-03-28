import SwiftUI

@main
struct GIFGalleryApp: App {
    @State private var viewModel = GalleryViewModel()

    var body: some Scene {
        WindowGroup {
            GalleryView(viewModel: viewModel)
                .frame(minWidth: 600, minHeight: 400)
        }

        Settings {
            SettingsView()
        }
    }
}
