import SwiftUI

#if canImport(AppKit)
import AppKit

public struct AnimatedGIFView: NSViewRepresentable {
    public let data: Data
    public var paused: Bool

    public init(data: Data, paused: Bool = false) {
        self.data = data
        self.paused = paused
    }

    public func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = !paused
        view.canDrawSubviewsIntoLayer = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    public func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image == nil {
            nsView.image = NSImage(data: data)
        }
        nsView.animates = !paused
    }
}

#elseif canImport(UIKit)
import ImageIO
import UIKit

/// Decoded frames for one GIF blob. Immutable, so safe to share across threads.
private final class DecodedGIF: @unchecked Sendable {
    let animated: UIImage?
    let first: UIImage?
    /// Approximate bitmap bytes, used as the NSCache cost.
    let cost: Int

    init(animated: UIImage?, first: UIImage?, cost: Int) {
        self.animated = animated
        self.first = first
        self.cost = cost
    }
}

public struct AnimatedGIFView: UIViewRepresentable {
    public let data: Data
    public var paused: Bool

    public init(data: Data, paused: Bool = false) {
        self.data = data
        self.paused = paused
    }

    /// Decoded GIFs shared across all cells, so scrolling back to a cell
    /// does not re-decode; cost-limited so bitmaps cannot pile up unbounded.
    private static let cache: NSCache<NSData, DecodedGIF> = {
        let cache = NSCache<NSData, DecodedGIF>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    public final class Coordinator {
        var pendingData: Data?
        var decodeTask: Task<Void, Never>?
        var paused = false

        deinit { decodeTask?.cancel() }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    public func updateUIView(_ uiView: UIImageView, context: Context) {
        let coordinator = context.coordinator
        coordinator.paused = paused

        if let decoded = Self.cache.object(forKey: data as NSData) {
            coordinator.decodeTask?.cancel()
            coordinator.pendingData = nil
            Self.apply(decoded, to: uiView, paused: paused)
            return
        }

        // Decode off the main thread, once per distinct data blob — decoding
        // is expensive and LazyVGrid re-creates this view when scrolling back.
        guard coordinator.pendingData != data else { return }
        coordinator.pendingData = data
        coordinator.decodeTask?.cancel()
        uiView.image = nil
        coordinator.decodeTask = Task { [data] in
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decodeGIF(data)
            }.value
            guard !Task.isCancelled else { return }
            Self.cache.setObject(decoded, forKey: data as NSData, cost: decoded.cost)
            coordinator.pendingData = nil
            Self.apply(decoded, to: uiView, paused: coordinator.paused)
        }
    }

    private static func apply(_ decoded: DecodedGIF, to view: UIImageView, paused: Bool) {
        let image = paused ? decoded.first : (decoded.animated ?? decoded.first)
        if view.image !== image {
            view.image = image
        }
    }

    /// Decodes a GIF into an animated UIImage plus its first frame.
    /// `UIImage.animatedImage(with:duration:)` plays frames at a uniform
    /// rate, so variable per-frame delays are honored by repeating each
    /// frame proportionally to its delay (repeats only append references,
    /// not bitmap copies; GIF delays are centisecond-quantized, so the
    /// repeat counts stay small).
    nonisolated private static func decodeGIF(_ data: Data) -> DecodedGIF {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return DecodedGIF(animated: nil, first: nil, cost: 0)
        }

        var frames: [UIImage] = []
        var delays: [Double] = []
        var cost = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            delays.append(frameDelay(source: source, index: index))
            cost += cgImage.bytesPerRow * cgImage.height
        }

        guard let first = frames.first else { return DecodedGIF(animated: nil, first: nil, cost: 0) }
        guard frames.count > 1 else { return DecodedGIF(animated: nil, first: first, cost: cost) }

        let totalDuration = delays.reduce(0, +)
        let ticks = delays.map { max(1, Int(($0 * 100).rounded())) }
        let unit = ticks.reduce(0, gcd)
        var sequence: [UIImage] = []
        if ticks.reduce(0, +) / unit <= 4096 {
            for (frame, tick) in zip(frames, ticks) {
                sequence.append(contentsOf: repeatElement(frame, count: tick / unit))
            }
        } else {
            // Degenerate delay mix; fall back to uniform pacing.
            sequence = frames
        }
        return DecodedGIF(
            animated: UIImage.animatedImage(with: sequence, duration: totalDuration),
            first: first,
            cost: cost
        )
    }

    nonisolated private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        let fallback = 0.1
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return fallback }

        let unclamped = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gifProperties[kCGImagePropertyGIFDelayTime] as? Double
        var delay = unclamped ?? clamped ?? fallback
        if delay <= 0 { delay = clamped ?? fallback }
        // Browsers (and ImageIO's clamped value, which the macOS client gets
        // via NSImage) promote delays of 10ms or less to 100ms; match that.
        if delay <= 0.010 { delay = fallback }
        return delay
    }

    nonisolated private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
#endif
