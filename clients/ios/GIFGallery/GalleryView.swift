import GIFKit
import SwiftUI

struct GalleryView: View {
    @Bindable var viewModel: GalleryViewModel
    @AppStorage("gridSize") private var gridSizeRaw = GridSize.medium.rawValue
    @State private var showSettings = false
    @State private var sharingGIF: GIFItem?
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private var gridSize: GridSize {
        GridSize(rawValue: gridSizeRaw) ?? .medium
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: gridSize.columnMinimum), spacing: 8)]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tagBar
                    .padding(.horizontal)
                    .padding(.top, 8)

                ScrollView {
                    if viewModel.isLoading && viewModel.gifs.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if viewModel.gifs.isEmpty {
                        ContentUnavailableView(
                            "No GIFs",
                            systemImage: "photo.on.rectangle.angled",
                            description: Text("Upload some GIFs to get started.")
                        )
                    } else {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(viewModel.gifs) { gif in
                                GIFGridItem(
                                    gif: gif,
                                    paused: viewModel.gifsPaused,
                                    gridSize: gridSize,
                                    loadData: { await viewModel.loadGIFData(for: gif) },
                                    onCopyEmbed: {
                                        viewModel.copyEmbedURL(gif)
                                        flash("Embed URL copied")
                                    },
                                    onCopyRaw: {
                                        viewModel.copyRawURL(gif)
                                        flash("Direct URL copied")
                                    },
                                    onSendToDiscord: { sharingGIF = gif },
                                    onEditTags: { viewModel.editingTagsGIF = gif },
                                    onRename: { viewModel.renamingGIF = gif },
                                    onDelete: { viewModel.deletingGIF = gif }
                                )
                            }
                        }
                        .padding()
                    }
                }
                .refreshable {
                    // Run the fetch outside the refresh task: SwiftUI cancels
                    // that task as soon as the view updates, which would kill
                    // the request mid-flight.
                    await Task { await viewModel.fetchGIFs() }.value
                }
            }
            .overlay(alignment: .bottom) {
                if let msg = toastMessage {
                    Text(msg)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toastMessage)
            .searchable(text: $viewModel.searchQuery)
            .onChange(of: viewModel.searchQuery) {
                viewModel.debouncedSearch()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { viewModel.showingUpload = true } label: {
                        Label("Upload", systemImage: "arrow.up.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("GIF Lobster")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await viewModel.fetchGIFs() }
        .sheet(isPresented: $showSettings, onDismiss: {
            // First-run: the launch fetch bailed while unconfigured, so load
            // as soon as the user closes settings with a server configured.
            Task { await viewModel.fetchGIFsIfConfigured() }
        }) { SettingsView() }
        .sheet(isPresented: $viewModel.showingUpload) {
            UploadSheet(viewModel: viewModel)
        }
        .sheet(item: $viewModel.editingTagsGIF) { gif in
            TagEditorSheet(gif: gif, viewModel: viewModel)
        }
        .sheet(item: $viewModel.renamingGIF) { gif in
            RenameSheet(gif: gif, viewModel: viewModel)
        }
        .sheet(item: $sharingGIF) { gif in
            // Share the raw GIF URL — Discord (and most chat apps) unfurl it
            // into the animated embed, same as pasting it.
            if let url = URL(string: gif.url) {
                ShareSheet(items: [url]) { completed in
                    sharingGIF = nil
                    if completed {
                        viewModel.trackShare(gif)
                        flash("Shared")
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .confirmationDialog(
            "Delete GIF?",
            isPresented: Binding(
                get: { viewModel.deletingGIF != nil },
                set: { if !$0 { viewModel.deletingGIF = nil } }
            ),
            presenting: viewModel.deletingGIF
        ) { gif in
            Button("Delete", role: .destructive) {
                Task { await viewModel.delete(gif) }
            }
        } message: { gif in
            Text("Permanently delete \"\(gif.title)\"? This cannot be undone.")
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            if !viewModel.isConfigured { showSettings = true }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.cancelAutoPauseAndResume()
            } else {
                viewModel.scheduleAutoPause()
            }
        }
    }

    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tagButton(label: "All", slug: nil)
                ForEach(viewModel.availableTags) { tag in
                    tagButton(label: tag.name, slug: tag.slug)
                }
            }
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

    private func flash(_ msg: String) {
        toastMessage = msg
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }
}
