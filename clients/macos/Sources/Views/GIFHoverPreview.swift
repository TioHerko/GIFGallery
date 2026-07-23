import AppKit
import GIFKit
import ImageIO
import SwiftUI

/// Floating panel that shows a single GIF full-size at its real aspect
/// ratio while the pointer rests on its grid cell.
///
/// The panel ignores mouse events and never becomes key, so it can sit
/// directly under the pointer without cancelling the hover that spawned it
/// or stealing focus from the search field.
@MainActor
final class GIFPreviewPanel {
    static let shared = GIFPreviewPanel()

    /// Pointer dwell before the preview appears.
    static let hoverDelay: Duration = .seconds(1)

    private var panel: NSPanel?
    /// GIF currently on screen, so a stale cell can only dismiss its own
    /// preview (hover-out of the old cell can arrive after hover-in of the
    /// new one).
    private var shownID: String?
    private var dismissMonitor: Any?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in MainActor.assumeIsolated { GIFPreviewPanel.shared.hide() } }
    }

    func show(data: Data, id: String, at point: NSPoint) {
        guard let size = Self.previewSize(for: data, near: point) else { return }

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: GIFPreviewContent(data: data))
        panel.setFrame(Self.frame(size: size, centeredOn: point), display: true)
        // Front, but without activating the app or taking key from the window.
        panel.orderFrontRegardless()
        shownID = id
        installDismissMonitor()
    }

    /// Hides the preview. With an `id`, only if that GIF is the one showing.
    func hide(id: String? = nil) {
        if let id, id != shownID { return }
        shownID = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
            self.dismissMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }

    /// Scrolling or clicking moves the grid out from under the pointer
    /// without necessarily ending the hover, so dismiss on both.
    private func installDismissMonitor() {
        guard dismissMonitor == nil else { return }
        dismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            MainActor.assumeIsolated { GIFPreviewPanel.shared.hide() }
            return event
        }
    }

    /// The GIF's pixel size, scaled to fit comfortably on the pointer's
    /// screen (and scaled up if it's tiny). Aspect ratio is preserved.
    private static func previewSize(for data: Data, near point: NSPoint) -> CGSize? {
        guard let natural = naturalSize(of: data), natural.width > 0, natural.height > 0
        else { return nil }

        let visible = (screen(containing: point) ?? .main)?.visibleFrame ?? .zero
        let maxWidth = max(visible.width * 0.6, 200)
        let maxHeight = max(visible.height * 0.6, 200)
        let longest = max(natural.width, natural.height)

        var scale = min(maxWidth / natural.width, maxHeight / natural.height)
        if longest < 320 {
            scale = min(scale, 320 / longest)
        } else {
            scale = min(scale, 1)
        }
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    private static func naturalSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Centres the preview on the pointer, nudged back onto the screen so it
    /// never hangs off an edge or under the menu bar.
    private static func frame(size: CGSize, centeredOn point: NSPoint) -> NSRect {
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let visible = (screen(containing: point) ?? .main)?.visibleFrame {
            let margin: CGFloat = 8
            origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        }
        return NSRect(origin: origin, size: size)
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

private struct GIFPreviewContent: View {
    let data: Data

    var body: some View {
        // Opaque backing so transparent GIFs stay readable over the grid.
        AnimatedGIFView(data: data, paused: false, contentMode: .fit)
            .background(Color(.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator, lineWidth: 1)
            }
    }
}

private struct GIFHoverPreviewModifier: ViewModifier {
    let gif: GIFItem
    let loadFullData: () async -> Data?

    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hoverTask?.cancel()
                guard inside else {
                    GIFPreviewPanel.shared.hide(id: gif.id)
                    return
                }
                hoverTask = Task {
                    try? await Task.sleep(for: GIFPreviewPanel.hoverDelay)
                    guard !Task.isCancelled, let data = await loadFullData(), !Task.isCancelled
                    else { return }
                    GIFPreviewPanel.shared.show(data: data, id: gif.id, at: NSEvent.mouseLocation)
                }
            }
            .onDisappear {
                hoverTask?.cancel()
                GIFPreviewPanel.shared.hide(id: gif.id)
            }
    }
}

extension View {
    /// Shows `gif` full-size in a floating panel after the pointer rests on
    /// this view for a moment.
    func gifHoverPreview(_ gif: GIFItem, loadFullData: @escaping () async -> Data?) -> some View {
        modifier(GIFHoverPreviewModifier(gif: gif, loadFullData: loadFullData))
    }
}
