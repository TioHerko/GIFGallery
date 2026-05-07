import AppKit
import SwiftUI

struct AnimatedGIFView: NSViewRepresentable {
    let data: Data
    var paused: Bool = false

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = !paused
        view.canDrawSubviewsIntoLayer = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image == nil {
            nsView.image = NSImage(data: data)
        }
        nsView.animates = !paused
    }
}
