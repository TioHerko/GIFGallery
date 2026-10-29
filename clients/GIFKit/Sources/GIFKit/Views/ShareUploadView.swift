import SwiftUI

/// Tagging + upload UI shared by the iOS and macOS share extensions.
/// Resolves the attachments to GIF payloads, lets the user tag them, and
/// uploads with the app-group credentials.
public struct ShareUploadView: View {
    private let providers: [NSItemProvider]
    private let onComplete: (_ uploaded: Bool) -> Void
    private let client = SharedStore.makeClient()

    @State private var payloads: [SharePayload] = []
    @State private var failures: [String] = []
    @State private var tags = ""
    @State private var titlePrefix = ""
    @State private var isLoading = true
    @State private var isUploading = false
    @State private var errorMessage: String?
    @State private var details = UploadDetails()

    public init(providers: [NSItemProvider], onComplete: @escaping (_ uploaded: Bool) -> Void) {
        self.providers = providers
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to GIF Lobster")
                .font(.headline)

            if client == nil {
                Text("Open GIF Lobster and configure the server URL and API token first.")
                    .foregroundStyle(.secondary)
                closeButton
            } else if isLoading {
                ProgressView("Reading GIFs…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if payloads.isEmpty {
                Text("Nothing that was shared can be uploaded.")
                    .foregroundStyle(.secondary)
                failureList
                closeButton
            } else {
                preview(for: payloads[0])
                    .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if payloads.count > 1 {
                    Text("\(payloads.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if payloads.contains(where: \.isVideo) {
                    Text("Videos are converted to GIFs on upload.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                failureList

                Group {
                    if details.isEnabled {
                        fileDetails
                    }
                    TextField(
                        details.isEnabled && payloads.count > 1
                            ? "Tags for all files (comma-separated)" : "Tags (comma-separated)",
                        text: $tags)
                    TextField("Title prefix (optional)", text: $titlePrefix)
                }
                .textFieldStyle(.roundedBorder)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    if isUploading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", role: .cancel) { onComplete(false) }
                    Button(payloads.count > 1 ? "Upload \(payloads.count)" : "Upload") {
                        upload()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isUploading)
                }
            }
        }
        .padding()
        #if os(macOS)
        .frame(width: 360)
        #endif
        .task { await loadAttachments() }
        .onDisappear { details.reset() }
    }

    /// Suggested title and tags per item; filenames label them only when
    /// there's more than one.
    @ViewBuilder
    private var fileDetails: some View {
        if payloads.count == 1 {
            UploadItemFields(details: details, id: payloads[0].id, filename: payloads[0].filename)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
            }
            .frame(maxHeight: 220)
        }
    }

    /// GIFs animate inline; videos (which the on-device decoder can't play
    /// as GIFs) get an icon placeholder with the filename.
    @ViewBuilder
    private func preview(for payload: SharePayload) -> some View {
        if payload.isVideo {
            VStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(payload.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
        } else {
            AnimatedGIFView(data: payload.data)
        }
    }

    @ViewBuilder
    private var failureList: some View {
        ForEach(failures, id: \.self) { failure in
            Text(failure)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button("Close") { onComplete(false) }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func loadAttachments() async {
        // Learn the server's video length limit so an over-long clip is
        // rejected here instead of after a wasted upload.
        var maxSeconds: Double?
        if let client { maxSeconds = try? await client.fetchConfig().videoMaxDurationSeconds }
        for provider in providers {
            do {
                let payload = try await GIFIngest.load(from: provider)
                if let maxSeconds,
                   let reason = await UploadMedia.overLengthReason(
                       data: payload.data, name: payload.filename, maxSeconds: maxSeconds) {
                    failures.append(reason)
                    continue
                }
                payloads.append(payload)
                // The extension has no gallery loaded, so no existing tags.
                details.analyze(payload.id, filename: payload.filename, existingTags: []) {
                    [data = payload.data] in data
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        isLoading = false
    }

    private func upload() {
        guard let client else { return }
        isUploading = true
        errorMessage = nil
        let payloads = payloads, tags = tags, titlePrefix = titlePrefix
        let itemDetails = details.details(for: payloads.map(\.id))
        Task {
            do {
                _ = try await client.upload(
                    payloads: payloads, tags: tags, titlePrefix: titlePrefix, details: itemDetails)
                onComplete(true)
            } catch {
                errorMessage = error.localizedDescription
                isUploading = false
            }
        }
    }
}
