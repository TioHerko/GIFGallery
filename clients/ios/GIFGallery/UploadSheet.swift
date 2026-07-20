import GIFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct UploadSheet: View {
    @Bindable var viewModel: GalleryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var pendingFiles: [PendingFile] = []
    @State private var stagingDir: URL?
    @State private var photoCounter = 0
    @State private var skippedCount = 0
    @State private var rejected: [String] = []
    @State private var showFileImporter = false
    @State private var tags = ""
    @State private var titlePrefix = ""
    @State private var isUploading = false

    /// Picked media is staged to a temp file right away so the sheet never
    /// holds every selection in memory at once (the upload body is built
    /// from disk by APIClient).
    private struct PendingFile: Identifiable {
        let id = UUID()
        let name: String
        let url: URL
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $photoSelection, matching: .any(of: [.images, .videos])) {
                        Label("Choose from Photos…", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Browse Files…", systemImage: "folder")
                    }

                    if pendingFiles.isEmpty {
                        Text("No files selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pendingFiles) { file in
                            HStack {
                                Text(file.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    pendingFiles.removeAll { $0.id == file.id }
                                    try? FileManager.default.removeItem(at: file.url)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    if skippedCount > 0 {
                        Text("Skipped \(skippedCount) unsupported item(s).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rejected, id: \.self) { reason in
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Short videos (MP4, MOV, MKV) are converted to GIFs on upload.")
                }

                Section("Details") {
                    TextField("Tags (comma-separated)", text: $tags)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Title prefix (optional)", text: $titlePrefix)
                }

                if isUploading {
                    Section {
                        ProgressView("Uploading…")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Upload GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") { doUpload() }
                        .disabled(pendingFiles.isEmpty || isUploading)
                }
            }
            .onChange(of: photoSelection) { _, items in
                loadPhotoItems(items)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: UploadMedia.pickerContentTypes,
                allowsMultipleSelection: true
            ) { result in
                importFiles(result)
            }
            .interactiveDismissDisabled(isUploading)
            .onDisappear { cleanupStaging() }
        }
    }

    private func ensureStagingDir() -> URL? {
        if let dir = stagingDir { return dir }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-upload-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            viewModel.errorMessage = error.localizedDescription
            return nil
        }
        stagingDir = dir
        return dir
    }

    private func cleanupStaging() {
        guard !isUploading, let dir = stagingDir else { return }
        try? FileManager.default.removeItem(at: dir)
        stagingDir = nil
        pendingFiles = []
    }

    /// Writes one validated file into the staging dir (off the main actor)
    /// and records it, deduplicating names as they are staged. The caller is
    /// responsible for giving `rawName` a correct extension (.gif / .mp4 / …).
    private func appendStaged(name rawName: String, data: Data, dir: URL) async {
        var name = rawName
        while pendingFiles.contains(where: { $0.name == name }) {
            name = "\(UUID().uuidString.prefix(8))-\(name)"
        }
        let url = dir.appendingPathComponent(name)
        do {
            try await Task.detached(priority: .utility) {
                try data.write(to: url)
            }.value
            pendingFiles.append(PendingFile(name: name, url: url))
        } catch {
            skippedCount += 1
        }
    }

    private func loadPhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoSelection = []
        Task {
            guard let dir = ensureStagingDir() else { return }
            let maxSeconds = await viewModel.videoMaxDurationSeconds()
            for item in items {
                // Sniff the bytes so only server-acceptable media (GIF or a
                // supported video) is staged, and name it by its real type.
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let described = UploadMedia.describe(data)
                else {
                    skippedCount += 1
                    continue
                }
                if described.contentType.hasPrefix("video/"), let maxSeconds,
                   let reason = await UploadMedia.overLengthReason(
                       data: data, name: "A selected video", maxSeconds: maxSeconds) {
                    rejected.append(reason)
                    continue
                }
                photoCounter += 1
                await appendStaged(name: "photo-\(photoCounter).\(described.ext)", data: data, dir: dir)
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        Task {
            guard let dir = ensureStagingDir() else { return }
            let maxSeconds = await viewModel.videoMaxDurationSeconds()
            for url in urls {
                // Copy the data out immediately — access to the security-scoped
                // resource ends as soon as we stop accessing it.
                let data = await Task.detached(priority: .utility) { () -> Data? in
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }.value
                guard let data, let described = UploadMedia.describe(data) else {
                    skippedCount += 1
                    continue
                }
                if described.contentType.hasPrefix("video/"), let maxSeconds,
                   let reason = await UploadMedia.overLengthReason(
                       data: data, name: url.lastPathComponent, maxSeconds: maxSeconds) {
                    rejected.append(reason)
                    continue
                }
                await appendStaged(name: url.lastPathComponent, data: data, dir: dir)
            }
        }
    }

    private func doUpload() {
        isUploading = true
        Task {
            await viewModel.upload(
                files: pendingFiles.map(\.url),
                tags: tags,
                titlePrefix: titlePrefix
            )
            isUploading = false
            cleanupStaging()
            dismiss()
        }
    }
}
