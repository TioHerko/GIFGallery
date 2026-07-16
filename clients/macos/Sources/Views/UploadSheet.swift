import GIFKit
import SwiftUI
import UniformTypeIdentifiers

struct UploadSheet: View {
    @Bindable var viewModel: GalleryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFiles: [URL] = []
    @State private var tags = ""
    @State private var titlePrefix = ""
    @State private var isUploading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upload GIFs")
                .font(.headline)

            HStack {
                Button("Choose Files...") { pickFiles() }
                Text(selectedFiles.isEmpty ? "No files selected" : "\(selectedFiles.count) file(s)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if !selectedFiles.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(selectedFiles, id: \.absoluteString) { url in
                            Text(url.lastPathComponent)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }

            TextField("Tags (comma-separated)", text: $tags)
            TextField("Title prefix (optional)", text: $titlePrefix)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Upload") { doUpload() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedFiles.isEmpty || isUploading)
            }

            if isUploading {
                ProgressView("Uploading...")
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.gif, UTType.image]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            selectedFiles = panel.urls
        }
    }

    private func doUpload() {
        isUploading = true
        Task {
            await viewModel.upload(files: selectedFiles, tags: tags, titlePrefix: titlePrefix)
            isUploading = false
            dismiss()
        }
    }
}
