import GIFKit
import SwiftUI
import UniformTypeIdentifiers

struct UploadSheet: View {
    @Bindable var viewModel: GalleryViewModel
    // Staged by drag & drop / Open With before the sheet appears; the file
    // picker appends to it.
    @Binding var payloads: [SharePayload]
    @Environment(\.dismiss) private var dismiss
    @State private var tags = ""
    @State private var titlePrefix = ""
    @State private var isUploading = false
    @State private var pickerError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upload GIFs")
                .font(.headline)

            HStack {
                Button("Choose Files...") { pickFiles() }
                Text(payloads.isEmpty ? "No files selected" : "\(payloads.count) file(s)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if !payloads.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(payloads) { payload in
                            Text(payload.filename)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }

            if let pickerError {
                Text(pickerError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextField("Tags (comma-separated)", text: $tags)
            TextField("Title prefix (optional)", text: $titlePrefix)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Upload") { doUpload() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(payloads.isEmpty || isUploading)
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
        panel.allowedContentTypes = [UTType.gif]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        pickerError = nil
        for url in panel.urls {
            do {
                payloads.append(try GIFIngest.ingest(fileURL: url))
            } catch {
                pickerError = error.localizedDescription
            }
        }
    }

    private func close() {
        payloads = []
        dismiss()
    }

    private func doUpload() {
        isUploading = true
        Task {
            await viewModel.upload(payloads: payloads, tags: tags, titlePrefix: titlePrefix)
            isUploading = false
            close()
        }
    }
}
