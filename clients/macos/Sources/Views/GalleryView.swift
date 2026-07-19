import GIFKit
import SwiftUI
import UniformTypeIdentifiers

struct GalleryView: View {
    @Bindable var viewModel: GalleryViewModel
    @AppStorage("gridSize") private var gridSizeRaw = GridSize.medium.rawValue
    @State private var showSettings = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

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
                                    gifData: viewModel.gifDataCache[gif.id],
                                    paused: viewModel.gifsPaused,
                                    gridSize: gridSize,
                                    onCopyEmbed: {
                                        viewModel.copyEmbedURL(gif)
                                        flash("Embed URL copied")
                                    },
                                    onCopyRaw: {
                                        viewModel.copyRawURL(gif)
                                        flash("Direct URL copied")
                                    },
                                    onSendToDiscord: {
                                        Task {
                                            if await viewModel.sendToDiscord(gif) {
                                                flash("Sent to Discord")
                                            }
                                        }
                                    },
                                    onEditTags: { viewModel.editingTagsGIF = gif },
                                    onRename: { viewModel.renamingGIF = gif },
                                    onDelete: { viewModel.deletingGIF = gif }
                                )
                                .task(id: gif.id) {
                                    await viewModel.loadGIFData(for: gif)
                                }
                            }
                        }
                        .padding()
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                    return true
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
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack {
                        TextField("Search", text: $viewModel.searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onChange(of: viewModel.searchQuery) {
                                viewModel.debouncedSearch()
                            }

                        Button { viewModel.showingUpload = true } label: {
                            Label("Upload", systemImage: "arrow.up.circle")
                        }

                        Button { Task { await viewModel.fetchGIFs() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
            }
            .navigationTitle("GIF Lobster")
        }
        .task { await viewModel.fetchGIFs() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $viewModel.showingUpload) {
            UploadSheet(viewModel: viewModel)
        }
        .sheet(item: $viewModel.editingTagsGIF) { gif in
            TagEditorSheet(gif: gif, viewModel: viewModel)
        }
        .sheet(item: $viewModel.renamingGIF) { gif in
            RenameSheet(gif: gif, viewModel: viewModel)
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            viewModel.scheduleAutoPause()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.cancelAutoPauseAndResume()
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

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                guard let url = await loadFileURL(from: provider),
                      url.pathExtension.lowercased() == "gif"
                else { continue }
                urls.append(url)
            }
            guard !urls.isEmpty else { return }
            await viewModel.upload(files: urls, tags: "", titlePrefix: "")
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}
