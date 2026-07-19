import GIFKit
import SwiftUI
import UIKit

/// Principal class of the share extension: hosts the shared SwiftUI
/// tagging/upload view over the attachments handed in by the system.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        SharedStore.configure()

        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { ($0 as? NSExtensionItem)?.attachments }
            .flatMap { $0 }

        let host = UIHostingController(
            rootView: ShareUploadView(providers: providers) { [weak self] uploaded in
                guard let context = self?.extensionContext else { return }
                if uploaded {
                    context.completeRequest(returningItems: nil)
                } else {
                    context.cancelRequest(withError: CocoaError(.userCancelled))
                }
            }
        )
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        view.backgroundColor = .systemBackground
    }
}
