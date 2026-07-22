import Foundation

public enum GridSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Minimum width for the adaptive grid columns.
    public var columnMinimum: CGFloat {
        switch self {
        case .small: return 130
        case .medium: return 200
        case .large: return 300
        }
    }

    /// Fixed height of a cell's media area (placeholder and GIF alike), so
    /// cells never reflow when their GIF finishes loading.
    public var mediaHeight: CGFloat {
        switch self {
        case .small: return 100
        case .medium: return 150
        case .large: return 220
        }
    }
}
