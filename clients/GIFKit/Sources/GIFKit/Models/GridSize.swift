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

    public var minHeight: CGFloat {
        switch self {
        case .small: return 70
        case .medium: return 100
        case .large: return 150
        }
    }

    public var maxHeight: CGFloat {
        switch self {
        case .small: return 190
        case .medium: return 300
        case .large: return 450
        }
    }

    /// Height of the placeholder shown while the GIF data loads.
    public var placeholderHeight: CGFloat {
        switch self {
        case .small: return 100
        case .medium: return 150
        case .large: return 220
        }
    }
}
