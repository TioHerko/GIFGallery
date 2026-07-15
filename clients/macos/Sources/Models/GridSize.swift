import Foundation

enum GridSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Minimum width for the adaptive grid columns.
    var columnMinimum: CGFloat {
        switch self {
        case .small: return 130
        case .medium: return 200
        case .large: return 300
        }
    }

    var minHeight: CGFloat {
        switch self {
        case .small: return 70
        case .medium: return 100
        case .large: return 150
        }
    }

    var maxHeight: CGFloat {
        switch self {
        case .small: return 190
        case .medium: return 300
        case .large: return 450
        }
    }

    /// Height of the placeholder shown while the GIF data loads.
    var placeholderHeight: CGFloat {
        switch self {
        case .small: return 100
        case .medium: return 150
        case .large: return 220
        }
    }
}
