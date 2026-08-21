import Foundation
import Testing
@testable import GIFKit

/// Builds a GIFItem the way the app really gets one — decoded from the
/// server's JSON — so the fixtures can't drift from the wire format.
private func makeGIF(_ title: String, copies: Int = 0, created: String) -> GIFItem {
    let json = """
    {"id": "\(title)", "title": "\(title)", "url": "https://example.test/\(title).gif",
     "thumbnail_url": null, "embed_url": "https://example.test/\(title)/",
     "tags": [], "copy_count": \(copies), "created_at": "\(created)"}
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(GIFItem.self, from: Data(json.utf8))
}

// Mixed case on purpose: a plain `<` on the titles would sort "Banana" first.
// "Banana" also carries fractional seconds, which Django emits only when the
// microseconds aren't zero.
private let apple = makeGIF("apple", copies: 5, created: "2026-08-17T10:00:00+00:00")
private let banana = makeGIF("Banana", copies: 0, created: "2026-08-18T10:00:00.500000+00:00")
private let cherry = makeGIF("cherry", copies: 2, created: "2026-08-19T10:00:00+00:00")
private let unsorted = [banana, cherry, apple]

private func titles(_ gifs: [GIFItem]) -> [String] { gifs.map(\.title) }

@Suite("GallerySort")
struct GallerySortTests {
    @Test("raw values match the server's ?sort= keys")
    func rawValuesMatchServerKeys() {
        #expect(GallerySort.allCases.map(\.rawValue) == [
            "newest", "oldest", "az", "za", "most_used", "least_used",
        ])
    }

    @Test("sorts newest first")
    func newestFirst() {
        #expect(titles(GallerySort.newest.sorted(unsorted)) == ["cherry", "Banana", "apple"])
    }

    @Test("sorts oldest first")
    func oldestFirst() {
        #expect(titles(GallerySort.oldest.sorted(unsorted)) == ["apple", "Banana", "cherry"])
    }

    @Test("alphabetical sort ignores case")
    func alphabeticalIgnoresCase() {
        #expect(titles(GallerySort.titleAscending.sorted(unsorted)) == ["apple", "Banana", "cherry"])
    }

    @Test("reverse alphabetical sort ignores case")
    func reverseAlphabeticalIgnoresCase() {
        #expect(titles(GallerySort.titleDescending.sorted(unsorted)) == ["cherry", "Banana", "apple"])
    }

    @Test("sorts by most used")
    func mostUsed() {
        #expect(titles(GallerySort.mostUsed.sorted(unsorted)) == ["apple", "cherry", "Banana"])
    }

    @Test("sorts by least used")
    func leastUsed() {
        #expect(titles(GallerySort.leastUsed.sorted(unsorted)) == ["Banana", "cherry", "apple"])
    }

    @Test("equally used GIFs fall back to newest first")
    func equalCountsTiebreakOnNewest() {
        let durian = makeGIF("durian", copies: 5, created: "2026-08-20T10:00:00+00:00")
        let sorted = GallerySort.mostUsed.sorted(unsorted + [durian])
        #expect(titles(sorted).prefix(2) == ["durian", "apple"])
    }

    @Test("only the frequency sorts show usage counts")
    func usageCountVisibility() {
        let showing = GallerySort.allCases.filter(\.showsUsageCount)
        #expect(showing == [.mostUsed, .leastUsed])
    }
}

@Suite("GIFItem timestamps")
struct GIFItemDateTests {
    @Test("parses timestamps without fractional seconds")
    func parsesWholeSeconds() {
        #expect(apple.createdDate != nil)
    }

    @Test("parses timestamps with fractional seconds")
    func parsesFractionalSeconds() {
        // Django's isoformat() only includes microseconds when they're
        // non-zero, so both shapes arrive from the same server.
        #expect(banana.createdDate != nil)
    }

    @Test("orders fractional and whole-second timestamps against each other")
    func ordersMixedPrecision() {
        #expect(apple.createdDate! < banana.createdDate!)
    }
}
