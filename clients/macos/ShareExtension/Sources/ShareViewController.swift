import AppKit
import GIFKit
import SwiftUI

/// Principal class of the macOS share extension. The explicit @objc name is
/// what NSExtensionPrincipalClass in the appex Info.plist resolves — no
/// module prefix, since this binary is assembled outside Xcode.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        SharedStore.configure()

        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { ($0 as? NSExtensionItem)?.attachments }
            .flatMap { $0 }

        let host = NSHostingView(
            rootView: ShareUploadView(providers: providers) { [weak self] uploaded in
                guard let context = self?.extensionContext else { return }
                if uploaded {
                    context.completeRequest(returningItems: nil)
                } else {
                    context.cancelRequest(withError: CocoaError(.userCancelled))
                }
            }
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
