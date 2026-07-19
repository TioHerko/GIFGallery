// Shortcuts / App Intents support.
//
// KEEP IN SYNC with clients/macos/Sources/GIFLobsterIntents.swift — the file
// is duplicated per app target (instead of living in GIFKit) because App
// Intents metadata extraction only reliably covers the app module itself,
// and the macOS bundle is assembled outside Xcode.
import AppIntents
import Foundation
import GIFKit
import UniformTypeIdentifiers

/// A GIF from the gallery, exposed to Shortcuts with its URLs and tags so
/// actions can be chained (e.g. random GIF → copy its embed URL).
struct GIFEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "GIF"
    static let defaultQuery = GIFEntityQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Direct URL")
    var url: URL

    @Property(title: "Embed URL")
    var embedURL: URL

    @Property(title: "Tags")
    var tags: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(tags.joined(separator: ", "))"
        )
    }

    init?(item: GIFItem) {
        guard let url = URL(string: item.url),
              let embedURL = URL(string: item.embedUrl)
        else { return nil }
        self.id = item.id
        self.title = item.title
        self.url = url
        self.embedURL = embedURL
        self.tags = item.tags.map(\.name)
    }
}

struct GIFEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [GIFEntity] {
        let wanted = Set(identifiers)
        return try await IntentSupport.allGIFs().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [GIFEntity] {
        try await IntentSupport.gifs(query: string)
    }

    func suggestedEntities() async throws -> [GIFEntity] {
        Array(try await IntentSupport.allGIFs().prefix(12))
    }
}

struct FindGIFsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find GIFs"
    static let description = IntentDescription(
        "Searches the gallery, optionally filtered by a tag.",
        categoryName: "Gallery"
    )

    @Parameter(title: "Search Text")
    var query: String?

    @Parameter(title: "Tag")
    var tag: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Find GIFs matching \(\.$query)") {
            \.$tag
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[GIFEntity]> {
        .result(value: try await IntentSupport.gifs(query: query, tag: tag))
    }
}

struct RandomGIFIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Random GIF"
    static let description = IntentDescription(
        "Picks a random GIF from the gallery, optionally from one tag.",
        categoryName: "Gallery"
    )

    @Parameter(title: "Tag")
    var tag: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Get a random GIF") {
            \.$tag
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let client = try IntentSupport.client()
        guard let gif = try await client.listGIFs(tag: tag).randomElement(),
              let url = URL(string: gif.url) else {
            throw IntentError.noMatches
        }
        // Download the actual GIF bytes so Shortcuts gets an image it can
        // save/share/preview, not just the entity metadata.
        let data = try await client.fetchGIFData(from: url)
        let safeName = gif.title.replacingOccurrences(of: "/", with: "-")
        let file = IntentFile(data: data, filename: "\(safeName).gif", type: .gif)
        return .result(value: file)
    }
}

struct UploadGIFsIntent: AppIntent {
    static let title: LocalizedStringResource = "Upload GIFs"
    static let description = IntentDescription(
        "Uploads GIFs to the gallery with optional tags.",
        categoryName: "Gallery"
    )

    // No supportedContentTypes: that initializer needs iOS 18, and the GIF
    // magic bytes are validated below anyway.
    @Parameter(title: "GIFs")
    var files: [IntentFile]

    @Parameter(title: "Tags (comma-separated)")
    var tags: String?

    @Parameter(title: "Title Prefix")
    var titlePrefix: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Upload \(\.$files)") {
            \.$tags
            \.$titlePrefix
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let client = try IntentSupport.client()
        let payloads = files.compactMap { file -> SharePayload? in
            guard GIFIngest.isGIF(file.data) else { return nil }
            return SharePayload(filename: file.filename, data: file.data)
        }
        guard !payloads.isEmpty else { throw IntentError.notAGIF }
        let created = try await client.upload(
            payloads: payloads,
            tags: tags ?? "",
            titlePrefix: titlePrefix ?? ""
        )
        return .result(value: created.count)
    }
}

struct GIFLobsterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RandomGIFIntent(),
            phrases: ["Get a random \(.applicationName) GIF"],
            shortTitle: "Random GIF",
            systemImageName: "photo.stack"
        )
        AppShortcut(
            intent: FindGIFsIntent(),
            phrases: ["Find GIFs in \(.applicationName)"],
            shortTitle: "Find GIFs",
            systemImageName: "magnifyingglass"
        )
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notConfigured
    case noMatches
    case notAGIF

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConfigured:
            "Open GIF Lobster and configure the server URL and API token first."
        case .noMatches:
            "No GIFs matched."
        case .notAGIF:
            "None of the files are GIFs."
        }
    }
}

enum IntentSupport {
    static func client() throws -> APIClient {
        SharedStore.configure()
        guard let client = SharedStore.makeClient() else {
            throw IntentError.notConfigured
        }
        return client
    }

    static func allGIFs() async throws -> [GIFEntity] {
        try await gifs()
    }

    static func gifs(query: String? = nil, tag: String? = nil) async throws -> [GIFEntity] {
        try await client()
            .listGIFs(tag: tag, query: query)
            .compactMap(GIFEntity.init)
    }
}
