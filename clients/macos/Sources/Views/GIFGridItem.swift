import SwiftUI

struct GIFGridItem: View {
    let gif: GIFItem
    let gifData: Data?
    let paused: Bool
    let onCopyEmbed: () -> Void
    let onCopyRaw: () -> Void
    let onEditTags: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let data = gifData {
                    AnimatedGIFView(data: data, paused: paused)
                        .frame(minHeight: 100, maxHeight: 300)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 150)
                        .overlay { ProgressView() }
                }

                if gif.copyCount > 0 {
                    Text("\(gif.copyCount)")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }

            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(gif.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !gif.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(gif.tags) { tag in
                                Text(tag.name)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { onCopyRaw() } label: {
                    Image(systemName: "link")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy direct GIF link")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onCopyEmbed)
        .contextMenu {
            Button("Copy Embed URL") { onCopyEmbed() }
            Button("Copy Direct URL") { onCopyRaw() }
            Divider()
            Button("Edit Tags...") { onEditTags() }
            Button("Rename...") { onRename() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}
