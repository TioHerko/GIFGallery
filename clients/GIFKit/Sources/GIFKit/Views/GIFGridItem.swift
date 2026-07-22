import SwiftUI

public struct GIFGridItem: View {
    public let gif: GIFItem
    public let paused: Bool
    public let gridSize: GridSize
    public let loadData: () async -> Data?
    public let onCopyEmbed: () -> Void
    public let onCopyRaw: () -> Void
    public let onSendToDiscord: () -> Void
    public let onEditTags: () -> Void
    public let onRename: () -> Void
    public let onDelete: () -> Void

    /// Loaded per cell so a finished download re-renders only this cell,
    /// not the whole grid.
    @State private var gifData: Data?

    public init(
        gif: GIFItem,
        paused: Bool,
        gridSize: GridSize,
        loadData: @escaping () async -> Data?,
        onCopyEmbed: @escaping () -> Void,
        onCopyRaw: @escaping () -> Void,
        onSendToDiscord: @escaping () -> Void,
        onEditTags: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.gif = gif
        self.loadData = loadData
        self.paused = paused
        self.gridSize = gridSize
        self.onCopyEmbed = onCopyEmbed
        self.onCopyRaw = onCopyRaw
        self.onSendToDiscord = onSendToDiscord
        self.onEditTags = onEditTags
        self.onRename = onRename
        self.onDelete = onDelete
    }

    // macOS pastes straight into Discord; iOS presents the share sheet.
    private var sendLabel: String {
        #if os(macOS)
        "Send to Discord"
        #else
        "Share"
        #endif
    }

    private var cardBackground: Color {
        #if os(macOS)
        Color(.controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let data = gifData {
                        AnimatedGIFView(data: data, paused: paused, contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(.quaternary)
                            .overlay { ProgressView() }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: gridSize.mediaHeight)
                .clipped()

                // Don't like the copy count
//                if gif.copyCount > 0 {
//                    Text("\(gif.copyCount)")
//                        .font(.caption2.weight(.medium))
//                        .padding(.horizontal, 5)
//                        .padding(.vertical, 2)
//                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
//                        .padding(6)
//                }
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

                Button { onCopyEmbed() } label: {
                    Image(systemName: "link")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy embed link")

                Button { onSendToDiscord() } label: {
                    #if os(macOS)
                    DiscordMark()
                        .fill(style: FillStyle(eoFill: true))
                        .frame(width: 14, height: 12)
                    #else
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                    #endif
                }
                .buttonStyle(.borderless)
                .help(sendLabel)

                Button { onRename() } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Rename")

                Button { onEditTags() } label: {
                    Image(systemName: "tag")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Edit tags")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: gif.id) {
            if gifData == nil {
                gifData = await loadData()
            }
        }
        .onTapGesture(perform: onCopyRaw)
        .contextMenu {
            Button("Copy Direct URL") { onCopyRaw() }
            Button("Copy Embed URL") { onCopyEmbed() }
            Button(sendLabel) { onSendToDiscord() }
            Divider()
            Button("Edit Tags...") { onEditTags() }
            Button("Rename...") { onRename() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}
