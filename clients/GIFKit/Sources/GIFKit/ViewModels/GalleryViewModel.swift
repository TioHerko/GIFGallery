#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Foundation
import Observation

@MainActor
@Observable
public final class GalleryViewModel {
    public var gifs: [GIFItem] = []
    public var gifDataCache: [String: Data] = [:]
    public var searchQuery = ""
    public var selectedTag: String?
    public var availableTags: [Tag] = []
    public var isLoading = false
    public var errorMessage: String?
    public var gifsPaused = false

    // Sheets
    public var editingTagsGIF: GIFItem?
    public var renamingGIF: GIFItem?
    public var showingUpload = false
    public var deletingGIF: GIFItem?

    private var searchTask: Task<Void, Never>?
    private var autoPauseTask: Task<Void, Never>?

    public static let autoPauseDelay: Duration = .seconds(15)

    public init() {}

    private var client: APIClient? {
        SharedStore.makeClient()
    }

    public var isConfigured: Bool {
        client != nil
    }

    public func fetchGIFs() async {
        guard isConfigured else { return }
        isLoading = true
        errorMessage = nil
        do {
            let tag = selectedTag?.isEmpty == true ? nil : selectedTag
            let query = searchQuery.isEmpty ? nil : searchQuery
            gifs = try await client!.listGIFs(tag: tag, query: query)
            rebuildTags()
        } catch is CancellationError {
            // SwiftUI cancels in-flight .task/.refreshable fetches on view
            // updates; not a user-facing failure.
        } catch let error as URLError where error.code == .cancelled {
            // Same as above, surfaced through URLSession.
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    public func fetchGIFsIfConfigured() async {
        guard isConfigured else { return }
        await fetchGIFs()
    }

    public func scheduleAutoPause() {
        autoPauseTask?.cancel()
        autoPauseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoPauseDelay)
            guard !Task.isCancelled else { return }
            self?.gifsPaused = true
        }
    }

    public func cancelAutoPauseAndResume() {
        autoPauseTask?.cancel()
        autoPauseTask = nil
        gifsPaused = false
    }

    public func debouncedSearch() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await fetchGIFs()
        }
    }

    public func loadGIFData(for gif: GIFItem) async {
        guard gifDataCache[gif.id] == nil, let client else { return }
        guard let url = URL(string: gif.displayUrl) else { return }
        do {
            let data = try await client.fetchGIFData(from: url)
            gifDataCache[gif.id] = data
        } catch {
            // Silently skip — the grid will show a placeholder
        }
    }

    /// Puts `text` on the system pasteboard.
    private func setPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    public func copyEmbedURL(_ gif: GIFItem) {
        setPasteboard(gif.embedUrl)
        Task { try? await client?.trackCopy(id: gif.id) }
    }

    public func copyRawURL(_ gif: GIFItem) {
        setPasteboard(gif.url)
        Task { try? await client?.trackCopy(id: gif.id) }
    }

    #if os(macOS)
    public func sendToDiscord(_ gif: GIFItem) async -> Bool {
        do {
            try await DiscordPaste.send(gif.url)
            Task { try? await client?.trackCopy(id: gif.id) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    #endif

    /// Records a completed share (e.g. via the iOS share sheet) against the
    /// server's copy counter.
    public func trackShare(_ gif: GIFItem) {
        Task { try? await client?.trackCopy(id: gif.id) }
    }

    public func updateTags(_ gif: GIFItem, tags: String) async {
        guard let client else { return }
        do {
            let newTags = try await client.updateTags(id: gif.id, tags: tags)
            if let idx = gifs.firstIndex(where: { $0.id == gif.id }) {
                gifs[idx].tags = newTags
                rebuildTags()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func rename(_ gif: GIFItem, to title: String) async {
        guard let client else { return }
        do {
            let newTitle = try await client.rename(id: gif.id, title: title)
            if let idx = gifs.firstIndex(where: { $0.id == gif.id }) {
                gifs[idx].title = newTitle
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ gif: GIFItem) async {
        guard let client else { return }
        do {
            try await client.delete(id: gif.id)
            gifs.removeAll { $0.id == gif.id }
            gifDataCache.removeValue(forKey: gif.id)
            rebuildTags()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func upload(files: [URL], tags: String, titlePrefix: String) async {
        guard let client else { return }
        do {
            _ = try await client.upload(files: files, tags: tags, titlePrefix: titlePrefix)
            await fetchGIFs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func upload(payloads: [SharePayload], tags: String, titlePrefix: String) async {
        guard let client else { return }
        do {
            _ = try await client.upload(payloads: payloads, tags: tags, titlePrefix: titlePrefix)
            await fetchGIFs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rebuildTags() {
        var seen = Set<String>()
        var tags: [Tag] = []
        for gif in gifs {
            for tag in gif.tags where seen.insert(tag.slug).inserted {
                tags.append(tag)
            }
        }
        availableTags = tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
