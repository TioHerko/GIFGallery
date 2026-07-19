import SwiftUI
import UIKit

/// UIActivityViewController wrapper. SwiftUI's ShareLink has no completion
/// callback, and we want to count only shares the user actually finishes.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (_ completed: Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
