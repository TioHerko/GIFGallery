import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class GalleryViewModel {
    var gifs: [GIFItem] = []
    var gifDataCache: [String: Data] = [:]
    var searchQuery = ""
    var selectedTag: String?
    var availableTags: [Tag] = []
    var isLoading = false
    var errorMessage: String?
    var gifsPaused = false

    // Sheets
    var editingTagsGIF: GIFItem?
    var renamingGIF: GIFItem?
    var showingUpload = false
    var deletingGIF: GIFItem?

    private var searchTask: Task<Void, Never>?
    private var autoPauseTask: Task<Void, Never>?

    static let autoPauseDelay: Duration = .seconds(15)

    private var client: APIClient? {
        guard let urlString = UserDefaults.standard.string(forKey: "serverURL"),
              !urlString.isEmpty,
              let url = URL(string: urlString),
              let token = UserDefaults.standard.string(forKey: "bearerToken"),
              !token.isEmpty
        else { return nil }
        return APIClient(baseURL: url, token: token)
    }

    var isConfigured: Bool {
        client != nil
    }

    func fetchGIFs() async {
        guard isConfigured else { return }
        isLoading = true
        errorMessage = nil
        do {
            let tag = selectedTag?.isEmpty == true ? nil : selectedTag
            let query = searchQuery.isEmpty ? nil : searchQuery
            gifs = try await client!.listGIFs(tag: tag, query: query)
            rebuildTags()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func fetchGIFsIfConfigured() async {
        guard isConfigured else { return }
        await fetchGIFs()
    }

    func scheduleAutoPause() {
        autoPauseTask?.cancel()
        autoPauseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoPauseDelay)
            guard !Task.isCancelled else { return }
            self?.gifsPaused = true
        }
    }

    func cancelAutoPauseAndResume() {
        autoPauseTask?.cancel()
        autoPauseTask = nil
        gifsPaused = false
    }

    func debouncedSearch() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await fetchGIFs()
        }
    }

    func loadGIFData(for gif: GIFItem) async {
        guard gifDataCache[gif.id] == nil, let client else { return }
        guard let url = URL(string: gif.displayUrl) else { return }
        do {
            let data = try await client.fetchGIFData(from: url)
            gifDataCache[gif.id] = data
        } catch {
            // Silently skip — the grid will show a placeholder
        }
    }

    func copyEmbedURL(_ gif: GIFItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(gif.embedUrl, forType: .string)
        Task { try? await client?.trackCopy(id: gif.id) }
    }

    func copyRawURL(_ gif: GIFItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(gif.url, forType: .string)
        Task { try? await client?.trackCopy(id: gif.id) }
    }

    func updateTags(_ gif: GIFItem, tags: String) async {
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

    func rename(_ gif: GIFItem, to title: String) async {
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

    func delete(_ gif: GIFItem) async {
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

    func upload(files: [URL], tags: String, titlePrefix: String) async {
        guard let client else { return }
        do {
            _ = try await client.upload(files: files, tags: tags, titlePrefix: titlePrefix)
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
