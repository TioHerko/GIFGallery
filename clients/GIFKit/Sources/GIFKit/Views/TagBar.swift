import SwiftUI

/// Tag filter bar. Collapsed it scrolls horizontally on a single line;
/// expanded it wraps onto as many lines as it takes to show every tag.
public struct TagBar: View {
    @Bindable var viewModel: GalleryViewModel
    @AppStorage("tagBarExpanded") private var expanded = false

    /// Caps the height of the expanded bar; once the tags exceed it they
    /// scroll instead of pushing the grid down. `nil` = unbounded (macOS).
    private let maxExpandedHeight: CGFloat?

    public init(viewModel: GalleryViewModel, maxExpandedHeight: CGFloat? = nil) {
        self.viewModel = viewModel
        self.maxExpandedHeight = maxExpandedHeight
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if expanded {
                    expandedTags
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { tagButtons }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !viewModel.availableTags.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(expanded ? "Show one line of tags" : "Show all tags")
                .accessibilityLabel(expanded ? "Collapse tags" : "Expand tags")
            }
        }
    }

    /// Wrapped tag chips. With a height cap, hug the content while it fits and
    /// switch to a vertical scroller once it would overflow the cap.
    @ViewBuilder private var expandedTags: some View {
        if let maxExpandedHeight {
            ViewThatFits(in: .vertical) {
                FlowLayout(spacing: 6) { tagButtons }
                ScrollView(.vertical) {
                    FlowLayout(spacing: 6) { tagButtons }
                }
            }
            .frame(maxHeight: maxExpandedHeight)
        } else {
            FlowLayout(spacing: 6) { tagButtons }
        }
    }

    @ViewBuilder private var tagButtons: some View {
        tagButton(label: "All", slug: nil)
        ForEach(viewModel.availableTags) { tag in
            tagButton(label: tag.name, slug: tag.slug)
        }
    }

    private func tagButton(label: String, slug: String?) -> some View {
        Button(label) {
            viewModel.selectedTag = slug
            Task { await viewModel.fetchGIFs() }
        }
        .buttonStyle(.bordered)
        .tint(viewModel.selectedTag == slug ? .accentColor : nil)
        .controlSize(.small)
    }
}

/// Left-aligned layout that wraps subviews onto new lines when they run out
/// of width — SwiftUI has no built-in equivalent.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && width > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = width
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
