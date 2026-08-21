import Foundation

/// How the gallery orders GIFs.
///
/// Raw values match the server's `?sort=` keys, so the same name means the
/// same order on the web. Sorting happens on the already-fetched list — the
/// API returns everything — so switching order costs no round trip.
///
/// Named GallerySort rather than SortOrder because Foundation already has a
/// `SortOrder`, and the two would collide at every call site.
public enum GallerySort: String, CaseIterable, Identifiable, Sendable {
    case newest
    case oldest
    case titleAscending = "az"
    case titleDescending = "za"
    case mostUsed = "most_used"
    case leastUsed = "least_used"

    public static let `default` = GallerySort.newest

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .titleAscending: "Title A–Z"
        case .titleDescending: "Title Z–A"
        case .mostUsed: "Most used"
        case .leastUsed: "Least used"
        }
    }

    public var systemImage: String {
        switch self {
        case .newest, .oldest: "calendar"
        case .titleAscending, .titleDescending: "textformat"
        case .mostUsed, .leastUsed: "chart.bar"
        }
    }

    /// Whether cells should show their usage count: only the sorts that rank
    /// by it, so the numbers explain the order they appear in.
    public var showsUsageCount: Bool {
        self == .mostUsed || self == .leastUsed
    }

    public func sorted(_ gifs: [GIFItem]) -> [GIFItem] {
        gifs.sorted(by: isOrderedBefore)
    }

    private func isOrderedBefore(_ a: GIFItem, _ b: GIFItem) -> Bool {
        switch self {
        case .newest:
            newerFirst(a, b)
        case .oldest:
            newerFirst(b, a)
        case .titleAscending:
            byTitle(a, b, ascending: true)
        case .titleDescending:
            byTitle(a, b, ascending: false)
        case .mostUsed:
            a.copyCount == b.copyCount ? newerFirst(a, b) : a.copyCount > b.copyCount
        case .leastUsed:
            a.copyCount == b.copyCount ? newerFirst(a, b) : a.copyCount < b.copyCount
        }
    }

    /// Ties break on id all the way down: Swift's sort isn't stable, so
    /// without a total order equally-ranked GIFs would shuffle on every
    /// re-sort. Undated GIFs (unparseable timestamp) sort last.
    private func newerFirst(_ a: GIFItem, _ b: GIFItem) -> Bool {
        let first = a.createdDate ?? .distantPast
        let second = b.createdDate ?? .distantPast
        return first == second ? a.id < b.id : first > second
    }

    private func byTitle(_ a: GIFItem, _ b: GIFItem, ascending: Bool) -> Bool {
        switch a.title.localizedCaseInsensitiveCompare(b.title) {
        case .orderedAscending: ascending
        case .orderedDescending: !ascending
        case .orderedSame: a.id < b.id
        }
    }
}
