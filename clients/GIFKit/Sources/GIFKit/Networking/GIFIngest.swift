import Foundation
import UniformTypeIdentifiers

/// One GIF ready to upload: raw bytes plus the filename to send.
public struct SharePayload: Identifiable, Sendable {
    public let id = UUID()
    public let filename: String
    public let data: Data

    public init(filename: String, data: Data) {
        self.filename = filename
        self.data = data
    }
}

public enum GIFIngestError: LocalizedError {
    case notAGIF(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notAGIF(let source): "\(source) isn't a GIF."
        case .unreadable(let source): "Couldn't read \(source)."
        }
    }
}

/// Turns share-sheet attachments — raw GIF data, files, or URLs pointing at
/// GIFs — into upload-ready payloads, validating the GIF magic bytes the same
/// way the server does.
public enum GIFIngest {
    public static func isGIF(_ data: Data) -> Bool {
        data.count >= 6
            && (data.prefix(6) == Data("GIF87a".utf8) || data.prefix(6) == Data("GIF89a".utf8))
    }

    // MainActor because NSItemProvider isn't Sendable; the work is all
    // continuation-based, so nothing blocks the main thread.
    @MainActor
    public static func load(from provider: NSItemProvider) async throws -> SharePayload {
        // Raw GIF data (Photos, image drags).
        if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
            let data = try await loadData(provider, type: UTType.gif.identifier)
            guard isGIF(data) else { throw GIFIngestError.notAGIF(sourceName(of: provider)) }
            return SharePayload(filename: gifFilename(suggested: provider.suggestedName), data: data)
        }
        // A file on disk.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url = try await loadURL(provider, type: UTType.fileURL.identifier)
            return try ingest(fileURL: url)
        }
        // A web URL — fetch it and check what came back really is a GIF.
        // (Checked after fileURL: public.file-url conforms to public.url.)
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try await loadURL(provider, type: UTType.url.identifier)
            return try await fetch(url)
        }
        // Any other image flavor: accept only if the bytes are a GIF.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data = try await loadData(provider, type: UTType.image.identifier)
            guard isGIF(data) else { throw GIFIngestError.notAGIF(sourceName(of: provider)) }
            return SharePayload(filename: gifFilename(suggested: provider.suggestedName), data: data)
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
        guard isGIF(data) else { throw GIFIngestError.notAGIF(url.absoluteString) }
        return SharePayload(filename: gifFilename(from: url), data: data)
    }

    public static func ingest(fileURL url: URL) throws -> SharePayload {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            throw GIFIngestError.unreadable(url.lastPathComponent)
        }
        guard isGIF(data) else { throw GIFIngestError.notAGIF(url.lastPathComponent) }
        return SharePayload(filename: gifFilename(from: url), data: data)
    }

    // MARK: - Helpers

    private static func gifFilename(from url: URL) -> String {
        gifFilename(suggested: url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
    }

    private static func gifFilename(suggested: String?) -> String {
        guard var name = suggested, !name.isEmpty, name != "/" else { return "shared.gif" }
        if !name.lowercased().hasSuffix(".gif") {
            name = (name as NSString).deletingPathExtension + ".gif"
        }
        return name
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
