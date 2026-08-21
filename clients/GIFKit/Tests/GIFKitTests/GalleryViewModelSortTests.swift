import Foundation
import Testing
@testable import GIFKit

@MainActor
@Suite("GalleryViewModel sorting", .serialized)
struct GalleryViewModelSortTests {
    /// The stored sort preference is process-wide, so each test runs against
    /// a cleared key and puts back whatever was there.
    private func withCleanPreference(_ body: () -> Void) {
        let key = GalleryViewModel.sortDefaultsKey
        let saved = SharedStore.defaults.string(forKey: key)
        SharedStore.defaults.removeObject(forKey: key)
        defer {
            if let saved {
                SharedStore.defaults.set(saved, forKey: key)
            } else {
                SharedStore.defaults.removeObject(forKey: key)
            }
        }
        body()
    }

    private func decodeGIF(_ title: String, created: String) -> GIFItem {
        let json = """
        {"id": "\(title)", "title": "\(title)", "url": "https://example.test/\(title).gif",
         "thumbnail_url": null, "embed_url": "https://example.test/\(title)/",
         "tags": [], "copy_count": 0, "created_at": "\(created)"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(GIFItem.self, from: Data(json.utf8))
    }

    @Test("starts out sorting newest first")
    func startsNewestFirst() {
        withCleanPreference {
            #expect(GalleryViewModel().sortOrder == .newest)
        }
    }

    @Test("presents GIFs in the selected order")
    func appliesSelectedSort() {
        withCleanPreference {
            let viewModel = GalleryViewModel()
            viewModel.gifs = [
                decodeGIF("zebra", created: "2026-08-19T10:00:00+00:00"),
                decodeGIF("apple", created: "2026-08-17T10:00:00+00:00"),
            ]
            #expect(viewModel.sortedGIFs.map(\.title) == ["zebra", "apple"])

            viewModel.sortOrder = .titleAscending
            #expect(viewModel.sortedGIFs.map(\.title) == ["apple", "zebra"])
        }
    }

    @Test("remembers the chosen sort for the next launch")
    func remembersChoice() {
        withCleanPreference {
            let viewModel = GalleryViewModel()
            viewModel.sortOrder = .leastUsed
            #expect(GalleryViewModel().sortOrder == .leastUsed)
        }
    }

    @Test("falls back to the default when the stored value is unusable")
    func ignoresUnknownStoredValue() {
        withCleanPreference {
            SharedStore.defaults.set("nonsense", forKey: GalleryViewModel.sortDefaultsKey)
            #expect(GalleryViewModel().sortOrder == .newest)
        }
    }
}
