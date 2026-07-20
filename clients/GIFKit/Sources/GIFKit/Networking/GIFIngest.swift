import Foundation
import UniformTypeIdentifiers

/// One item ready to upload: raw bytes, the filename to send, and the MIME
/// type for the multipart part. May be a GIF or a short video the server
/// transcodes to a GIF on upload.
public struct SharePayload: Identifiable, Sendable {
    public let id = UUID()
    public let filename: String
    public let data: Data
    public let contentType: String

    /// `contentType` defaults to whatever the filename extension implies
    /// (falling back to `image/gif` for back-compatibility with GIF-only
    /// callers).
    public init(filename: String, data: Data, contentType: String? = nil) {
        self.filename = filename
        self.data = data
        self.contentType = contentType ?? UploadMedia.contentType(forFilename: filename)
    }

    public var isVideo: Bool { contentType.hasPrefix("video/") }
}

/// Magic-byte sniffing and type mapping for the media the server accepts:
/// GIFs and short videos (mp4/mov/mkv/webm). Mirrors the server's
/// `_classify_upload` / `looks_like_video`.
public enum UploadMedia {
    /// Container extensions the server transcodes to GIF.
    public static let videoExtensions: [String] = ["mp4", "mov", "mkv", "m4v", "webm"]

    /// Content types to offer in file pickers (NSOpenPanel / `.fileImporter`):
    /// GIFs plus the videos the server can transcode. `.movie` covers
    /// mp4/mov/m4v; mkv/webm are added by extension since the system UTI
    /// database may not map them.
    public static var pickerContentTypes: [UTType] {
        var types: [UTType] = [.gif, .movie]
        for ext in ["mkv", "webm"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    public static func isGIF(_ data: Data) -> Bool {
        data.count >= 6
            && (data.prefix(6) == Data("GIF87a".utf8) || data.prefix(6) == Data("GIF89a".utf8))
    }

    public static func isVideo(_ data: Data) -> Bool {
        // MP4 / MOV (ISO base media): a top-level atom name at bytes 4..8.
        if data.count >= 8 {
            let atom = data.subdata(in: 4..<8)
            let atoms = ["ftyp", "moov", "mdat", "free", "skip", "wide", "pnot"]
                .map { Data($0.utf8) }
            if atoms.contains(atom) { return true }
        }
        // Matroska / WebM (EBML) signature.
        if data.count >= 4 && data.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]) { return true }
        return false
    }

    /// A supported blob's preferred file extension and MIME type, or nil if
    /// the bytes are neither a GIF nor a recognized video.
    public static func describe(_ data: Data) -> (ext: String, contentType: String)? {
        if isGIF(data) { return ("gif", "image/gif") }
        guard isVideo(data) else { return nil }
        if data.count >= 4 && data.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]) {
            return ("mkv", "video/x-matroska")
        }
        // ISO base media: distinguish QuickTime from MP4 by the major brand
        // (bytes 8..12) when present.
        if data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) {
            let brand = data.subdata(in: 8..<12)
            if brand.prefix(2) == Data("qt".utf8) { return ("mov", "video/quicktime") }
        }
        return ("mp4", "video/mp4")
    }

    public static func contentType(forFilename name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "gif": return "image/gif"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
}

public enum GIFIngestError: LocalizedError {
    case unsupported(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let source): "\(source) isn't a GIF or a supported video."
        case .unreadable(let source): "Couldn't read \(source)."
        }
    }
}

/// Turns share-sheet attachments — raw GIF/video data, files, or URLs — into
/// upload-ready payloads, validating the magic bytes the same way the server
/// does before sending anything over the wire.
public enum GIFIngest {
    public static func isGIF(_ data: Data) -> Bool { UploadMedia.isGIF(data) }

    // MainActor because NSItemProvider isn't Sendable; the work is all
    // continuation-based, so nothing blocks the main thread.
    @MainActor
    public static func load(from provider: NSItemProvider) async throws -> SharePayload {
        // Raw GIF data (Photos, image drags).
        if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
            let data = try await loadData(provider, type: UTType.gif.identifier)
            guard UploadMedia.isGIF(data) else { throw GIFIngestError.unsupported(sourceName(of: provider)) }
            return SharePayload(filename: gifFilename(suggested: provider.suggestedName), data: data,
                                contentType: "image/gif")
        }
        // A file on disk (GIF or video) — read from disk to avoid holding a
        // whole movie in memory twice.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url = try await loadURL(provider, type: UTType.fileURL.identifier)
            return try ingest(fileURL: url)
        }
        // A web URL — fetch it and check what came back is acceptable.
        // (Checked after fileURL: public.file-url conforms to public.url.)
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try await loadURL(provider, type: UTType.url.identifier)
            return try await fetch(url)
        }
        // A video handed over as data (e.g. Photos videos).
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            let typeID = videoTypeIdentifier(for: provider) ?? UTType.movie.identifier
            let data = try await loadData(provider, type: typeID)
            guard let described = UploadMedia.describe(data), described.contentType.hasPrefix("video/") else {
                throw GIFIngestError.unsupported(sourceName(of: provider))
            }
            let ext = UTType(typeID)?.preferredFilenameExtension ?? described.ext
            return SharePayload(filename: mediaFilename(suggested: provider.suggestedName, ext: ext),
                                data: data, contentType: described.contentType)
        }
        // Any other image flavor: accept only if the bytes are a GIF.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data = try await loadData(provider, type: UTType.image.identifier)
            guard UploadMedia.isGIF(data) else { throw GIFIngestError.unsupported(sourceName(of: provider)) }
            return SharePayload(filename: gifFilename(suggested: provider.suggestedName), data: data,
                                contentType: "image/gif")
        }
        throw GIFIngestError.unreadable(sourceName(of: provider))
    }

    public static func fetch(_ url: URL) async throws -> SharePayload {
        if url.isFileURL { return try ingest(fileURL: url) }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw GIFIngestError.unreadable(url.absoluteString)
        }
        return try payload(from: data, name: url.lastPathComponent, source: url.absoluteString)
    }

    public static func ingest(fileURL url: URL) throws -> SharePayload {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            throw GIFIngestError.unreadable(url.lastPathComponent)
        }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return try payload(from: data, name: name, source: url.lastPathComponent)
    }

    // MARK: - Helpers

    /// Builds a payload from raw bytes, choosing filename/content-type by
    /// sniffing. Throws if the bytes are neither GIF nor supported video.
    private static func payload(from data: Data, name: String, source: String) throws -> SharePayload {
        if UploadMedia.isGIF(data) {
            return SharePayload(filename: gifFilename(suggested: name), data: data, contentType: "image/gif")
        }
        guard let described = UploadMedia.describe(data) else {
            throw GIFIngestError.unsupported(source)
        }
        // Keep the original name if it already carries a video extension;
        // otherwise use the sniffed one so the server (and title) behave.
        let ext = (name as NSString).pathExtension.lowercased()
        let filename = UploadMedia.videoExtensions.contains(ext)
            ? name
            : mediaFilename(suggested: name, ext: described.ext)
        return SharePayload(filename: filename, data: data, contentType: described.contentType)
    }

    private static func gifFilename(suggested: String?) -> String {
        guard var name = suggested, !name.isEmpty, name != "/" else { return "shared.gif" }
        if !name.lowercased().hasSuffix(".gif") {
            name = (name as NSString).deletingPathExtension + ".gif"
        }
        return name
    }

    private static func mediaFilename(suggested: String?, ext: String) -> String {
        guard var name = suggested, !name.isEmpty, name != "/" else { return "shared.\(ext)" }
        if (name as NSString).pathExtension.isEmpty {
            name = (name as NSString).appendingPathExtension(ext) ?? "\(name).\(ext)"
        }
        return name
    }

    private static func videoTypeIdentifier(for provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .movie)
        }
    }

    private static func sourceName(of provider: NSItemProvider) -> String {
        provider.suggestedName ?? "The shared item"
    }

    @MainActor
    private static func loadData(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? GIFIngestError.unreadable("The shared item"))
                }
            }
        }
    }

    @MainActor
    private static func loadURL(_ provider: NSItemProvider, type: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type) { item, error in
                // Providers hand URLs back as NSURL or as bookmark-style Data
                // depending on the source app.
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let text = item as? String, let url = URL(string: text) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? GIFIngestError.unreadable("The shared item"))
                }
            }
        }
    }
}
