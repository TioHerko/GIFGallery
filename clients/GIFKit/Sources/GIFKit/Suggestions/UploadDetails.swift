import Foundation
import Observation
import SwiftUI

/// A title and tags for one uploaded file, applied after the upload: the
/// upload endpoint itself only takes batch-wide tags and derives titles from
/// filenames.
public struct UploadItemDetails: Sendable, Equatable {
    public var title: String
    /// Comma-separated, added to the batch-wide tags.
    public var tags: String

    public init(title: String, tags: String) {
        self.title = title
        self.tags = tags
    }

    var isEmpty: Bool { title.isEmpty && tags.isEmpty }
}

/// Per-file titles and tags for an upload batch, keyed by the staged item's
/// id and prefilled by `UploadSuggester` as each file is analyzed.
///
/// Files are analyzed one at a time, in the order they were staged: the
/// on-device model serves one request per session and throttles bursts.
@MainActor
@Observable
public final class UploadDetails {
    public struct Entry {
        public var title = ""
        public var tags = ""
        public var isAnalyzing = false
    }

    private var entries: [UUID: Entry] = [:]
    /// Ids handed to `analyze`, tracked apart from `entries`: a field's
    /// binding creates an entry as soon as it writes back — macOS does that
    /// just by focusing a field — which must not count as "already queued".
    @ObservationIgnored private var queued: Set<UUID> = []
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    /// Whether suggestions can run on this device, i.e. whether the per-file
    /// fields are worth showing at all.
    public let isEnabled: Bool

    public convenience init() {
        self.init(isEnabled: UploadSuggester.isAvailable)
        suggestionLog.debug("Upload details created; suggestions enabled: \(self.isEnabled)")
    }

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public func entry(for id: UUID) -> Entry {
        entries[id] ?? Entry()
    }

    public func title(for id: UUID) -> Binding<String> {
        Binding(get: { self.entry(for: id).title }, set: { self.entries[id, default: Entry()].title = $0 })
    }

    public func tags(for id: UUID) -> Binding<String> {
        Binding(get: { self.entry(for: id).tags }, set: { self.entries[id, default: Entry()].tags = $0 })
    }

    /// Queues `id` for a suggestion. `data` is loaded only when its turn
    /// comes, so a big batch isn't all held in memory up front.
    public func analyze(
        _ id: UUID,
        filename: String,
        existingTags: [String],
        data: @escaping @Sendable () async -> Data?
    ) {
        guard isEnabled, queued.insert(id).inserted else { return }
        suggestionLog.debug("Queued \(filename, privacy: .public) for a suggestion")
        entries[id, default: Entry()].isAnalyzing = true
        let previous = tail
        let task = Task {
            await previous?.value
            guard !Task.isCancelled, queued.contains(id) else { return }
            var suggestion: UploadSuggestion?
            if let bytes = await data() {
                suggestion = await UploadSuggester.suggest(
                    data: bytes, filename: filename, existingTags: existingTags)
            }
            apply(suggestion, to: id)
        }
        tail = task
        tasks.append(task)
    }

    /// Fills only the fields the user hasn't typed into while waiting.
    private func apply(_ suggestion: UploadSuggestion?, to id: UUID) {
        guard queued.contains(id) else { return }
        var entry = entries[id] ?? Entry()
        entry.isAnalyzing = false
        if let suggestion {
            if entry.title.isEmpty { entry.title = suggestion.title }
            if entry.tags.isEmpty { entry.tags = suggestion.tags.joined(separator: ", ") }
        }
        entries[id] = entry
    }

    public func remove(_ id: UUID) {
        queued.remove(id)
        entries[id] = nil
    }

    /// Stops pending analysis and forgets every entry.
    public func reset() {
        tasks.forEach { $0.cancel() }
        tasks = []
        tail = nil
        queued = []
        entries = [:]
    }

    /// What to apply to each uploaded file, aligned with `ids`.
    public func details(for ids: [UUID]) -> [UploadItemDetails?] {
        ids.map { id in
            guard let entry = entries[id] else { return nil }
            let details = UploadItemDetails(
                title: entry.title.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: entry.tags.trimmingCharacters(in: .whitespacesAndNewlines))
            return details.isEmpty ? nil : details
        }
    }
}

/// Title and tag fields for one staged file, with a spinner while its
/// suggestion is being worked out. Leaving the title empty keeps the
/// server's default (the filename), shown as the placeholder.
public struct UploadItemFields: View {
    private let details: UploadDetails
    private let id: UUID
    private let filename: String

    public init(details: UploadDetails, id: UUID, filename: String) {
        self.details = details
        self.id = id
        self.filename = filename
    }

    public var body: some View {
        let analyzing = details.entry(for: id).isAnalyzing
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(
                    "Title",
                    text: details.title(for: id),
                    prompt: Text(analyzing ? "Suggesting a title…" : (filename as NSString).deletingPathExtension)
                )
                if analyzing {
                    ProgressView().controlSize(.small)
                }
            }
            TextField("Tags", text: details.tags(for: id), prompt: Text("Tags for this file"))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
        }
    }
}
