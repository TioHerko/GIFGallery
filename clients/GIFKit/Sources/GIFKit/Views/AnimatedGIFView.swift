import ImageIO
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Layer-backed view that plays an animated GIF with ImageIO's incremental
// animator (`CGAnimateImageDataWithBlock`): frames are decoded off the main
// thread one at a time with native per-frame delays, so memory stays at
// roughly one frame per visible cell and scrolling never waits on a decode.
// The class is declared per platform (stored properties can't live in an
// extension); all playback logic is in the shared extension below.

#if canImport(AppKit)
public final class GIFPlayerView: NSView {
    var data: Data?
    var paused = false
    /// Invalidates in-flight animation callbacks: each started animation
    /// captures the value at start and stops itself once it goes stale.
    var generation = 0

    var contentLayer: CALayer { layer! }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        configureLayer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncPlayback()
    }
}
#elseif canImport(UIKit)
public final class GIFPlayerView: UIView {
    var data: Data?
    var paused = false
    /// Invalidates in-flight animation callbacks: each started animation
    /// captures the value at start and stops itself once it goes stale.
    var generation = 0

    var contentLayer: CALayer { layer }

    init() {
        super.init(frame: .zero)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        syncPlayback()
    }
}
#endif

extension GIFPlayerView {
    func configureLayer() {
        // Direct .contents updates; no implicit crossfade per frame.
        contentLayer.actions = ["contents": NSNull()]
        contentLayer.masksToBounds = true
    }

    func configure(data: Data, paused: Bool, gravity: CALayerContentsGravity) {
        contentLayer.contentsGravity = gravity
        guard data != self.data || paused != self.paused else { return }
        self.data = data
        self.paused = paused
        syncPlayback()
    }

    /// Starts or stops playback to match the current state. Also runs on
    /// window changes so cells recycled off-screen stop burning CPU.
    func syncPlayback() {
        generation += 1
        guard let data else {
            contentLayer.contents = nil
            return
        }
        guard window != nil, !paused else {
            contentLayer.contents = Self.firstFrame(of: data)
            return
        }

        let expected = generation
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, frame, stop in
            // ImageIO delivers frames on the main queue.
            MainActor.assumeIsolated {
                guard let self, self.generation == expected else {
                    stop.pointee = true
                    return
                }
                self.contentLayer.contents = frame
            }
        }
        if status != noErr {
            contentLayer.contents = Self.firstFrame(of: data)
        }
    }

    static func firstFrame(of data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

public struct AnimatedGIFView {
    public let data: Data
    public var paused: Bool
    public var contentMode: ContentMode

    public init(data: Data, paused: Bool = false, contentMode: ContentMode = .fit) {
        self.data = data
        self.paused = paused
        self.contentMode = contentMode
    }

    fileprivate var gravity: CALayerContentsGravity {
        contentMode == .fill ? .resizeAspectFill : .resizeAspect
    }
}

#if canImport(AppKit)
extension AnimatedGIFView: NSViewRepresentable {
    public func makeNSView(context: Context) -> GIFPlayerView {
        GIFPlayerView()
    }

    public func updateNSView(_ nsView: GIFPlayerView, context: Context) {
        nsView.configure(data: data, paused: paused, gravity: gravity)
    }
}
#elseif canImport(UIKit)
extension AnimatedGIFView: UIViewRepresentable {
    public func makeUIView(context: Context) -> GIFPlayerView {
        GIFPlayerView()
    }

    public func updateUIView(_ uiView: GIFPlayerView, context: Context) {
        uiView.configure(data: data, paused: paused, gravity: gravity)
    }
}
#endif
