import Foundation

#if canImport(AVFoundation)
import AVFoundation

/// Client-side video-duration checks, so an over-long clip is rejected before
/// it's uploaded. The server (which owns the real limit, reported via
/// `GET /api/config/`) still validates authoritatively; these checks just fail
/// fast. When a duration can't be read the item passes — the server decides.
extension UploadMedia {
    /// Duration in seconds of the video at `url`, or nil if it isn't a
    /// readable video.
    public static func videoDuration(url: URL) async -> Double? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return (seconds.isFinite && seconds > 0) ? seconds : nil
    }

    /// Duration of a video blob, probed via a temp file (AVFoundation reads
    /// from URLs, not Data). Returns nil for non-videos or unreadable clips.
    public static func videoDuration(data: Data) async -> Double? {
        guard let described = describe(data), described.contentType.hasPrefix("video/") else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-dur-\(UUID().uuidString).\(described.ext)")
        guard (try? data.write(to: tmp)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return await videoDuration(url: tmp)
    }

    /// A user-facing reason to reject `data` (a video longer than
    /// `maxSeconds`), or nil if it's within the limit / not a video. A half
    /// second of slack absorbs rounding between the container and the server.
    public static func overLengthReason(data: Data, name: String, maxSeconds: Double) async -> String? {
        guard let seconds = await videoDuration(data: data) else { return nil }
        return seconds > maxSeconds + 0.5 ? overLengthMessage(name: name, seconds: seconds, maxSeconds: maxSeconds) : nil
    }

    /// Same as above for a file on disk (skips non-video extensions cheaply).
    public static func overLengthReason(url: URL, maxSeconds: Double) async -> String? {
        guard videoExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        guard let seconds = await videoDuration(url: url) else { return nil }
        return seconds > maxSeconds + 0.5 ? overLengthMessage(name: url.lastPathComponent, seconds: seconds, maxSeconds: maxSeconds) : nil
    }

    private static func overLengthMessage(name: String, seconds: Double, maxSeconds: Double) -> String {
        String(format: "%@ is %.1fs long; the limit is %ds.", name, seconds, Int(maxSeconds))
    }
}
#endif
