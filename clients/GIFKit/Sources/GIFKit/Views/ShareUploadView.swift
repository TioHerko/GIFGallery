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
                Text("Nothing that was shared is a GIF.")
                    .foregroundStyle(.secondary)
                failureList
                closeButton
            } else {
                AnimatedGIFView(data: payloads[0].data)
                    .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if payloads.count > 1 {
                    Text("\(payloads.count) GIFs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                failureList

                TextField("Tags (comma-separated)", text: $tags)
                    .textFieldStyle(.roundedBorder)
                TextField("Title prefix (optional)", text: $titlePrefix)
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
        for provider in providers {
            do {
                payloads.append(try await GIFIngest.load(from: provider))
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
        Task {
            do {
                _ = try await client.upload(payloads: payloads, tags: tags, titlePrefix: titlePrefix)
                onComplete(true)
            } catch {
                errorMessage = error.localizedDescription
                isUploading = false
            }
        }
    }
}
