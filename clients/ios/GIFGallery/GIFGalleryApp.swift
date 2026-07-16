import GIFKit
import SwiftUI

@main
struct GIFGalleryApp: App {
    static let viewModel = GalleryViewModel()

    var body: some Scene {
        WindowGroup {
            GalleryView(viewModel: Self.viewModel)
        }
    }
}
