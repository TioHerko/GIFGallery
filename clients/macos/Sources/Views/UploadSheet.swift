import GIFKit
import SwiftUI
import UniformTypeIdentifiers

struct UploadSheet: View {
    @Bindable var viewModel: GalleryViewModel
    // Staged by drag & drop / Open With before the sheet appears; the file
    // picker and drops onto the sheet append to it.
    @Binding var payloads: [SharePayload]
    @Environment(\.dismiss) private var dismiss
    @State private var tags = ""
    @State private var titlePrefix = ""
    @State private var isUploading = false
    @State private var pickerError: String?
    @State private var details = UploadDetails()
    @State private var isDropTargeted = false

    /// What the gallery and this sheet accept as drops.
    static let dropTypes: [UTType] = [.gif, .movie, .fileURL, .url]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upload GIFs")
                .font(.headline)

            HStack {
                Button("Choose Files...") { pickFiles() }
                Text(payloads.isEmpty ? "No files selected — or drop them here" : "\(payloads.count) file(s)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if !payloads.isEmpty {
                if details.isEnabled {
                    fileDetails
                } else {
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
            }

            if let pickerError {
                Text(pickerError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextField(details.isEnabled ? "Tags for all files (comma-separated)" : "Tags (comma-separated)",
                      text: $tags)
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
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
            }
        }
        .onDrop(of: Self.dropTypes, isTargeted: $isDropTargeted) { providers in
            Task {
                let (dropped, error) = await Self.load(providers, viewModel: viewModel)
                payloads.append(contentsOf: dropped)
                pickerError = error
            }
            return true
        }
        // Staged payloads arrive before the sheet opens (gallery drops, Open
        // With), from the picker, and from drops onto the sheet; analyze()
        // skips any already queued.
        .task(id: payloads.map(\.id)) {
            let existingTags = viewModel.availableTags.map(\.name)
            for payload in payloads {
                details.analyze(payload.id, filename: payload.filename, existingTags: existingTags) {
                    [data = payload.data] in data
                }
            }
        }
    }

    /// A title and tags row per file, prefilled with suggestions. Scrolls
    /// once there are more than a couple.
    @ViewBuilder
    private var fileDetails: some View {
        let rows = VStack(alignment: .leading, spacing: 12) {
            ForEach(payloads) { payload in
                VStack(alignment: .leading, spacing: 4) {
                    Text(payload.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    UploadItemFields(details: details, id: payload.id, filename: payload.filename)
                }
            }
        }
        if payloads.count > 2 {
            ScrollView { rows.padding(.trailing, 12) }
                .frame(height: 260)
        } else {
            rows
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = UploadMedia.pickerContentTypes
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            pickerError = nil
            let maxSeconds = await viewModel.videoMaxDurationSeconds()
            for url in urls {
                if let maxSeconds,
                   let reason = await UploadMedia.overLengthReason(url: url, maxSeconds: maxSeconds) {
                    pickerError = reason
                    continue
                }
                do {
                    payloads.append(try GIFIngest.ingest(fileURL: url))
                } catch {
                    pickerError = error.localizedDescription
                }
            }
        }
    }

    /// Resolves dropped items — files, raw image data, or URLs pointing at
    /// GIFs — into payloads, skipping anything unsupported or over the
    /// server's video length limit. Returns the first reason something was
    /// skipped.
    static func load(
        _ providers: [NSItemProvider], viewModel: GalleryViewModel
    ) async -> (payloads: [SharePayload], firstError: String?) {
        var payloads: [SharePayload] = []
        var firstError: String?
        let maxSeconds = await viewModel.videoMaxDurationSeconds()
        for provider in providers {
            do {
                let payload = try await GIFIngest.load(from: provider)
                if let maxSeconds,
                   let reason = await UploadMedia.overLengthReason(
                       data: payload.data, name: payload.filename, maxSeconds: maxSeconds) {
                    if firstError == nil { firstError = reason }
                    continue
                }
                payloads.append(payload)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        return (payloads, firstError)
    }

    private func close() {
        payloads = []
        details.reset()
        dismiss()
    }

    private func doUpload() {
        isUploading = true
        Task {
            await viewModel.upload(
                payloads: payloads,
                tags: tags,
                titlePrefix: titlePrefix,
                details: details.details(for: payloads.map(\.id))
            )
            isUploading = false
            close()
        }
    }
}
