import SwiftUI

public struct SettingsView: View {
    // The server URL lives in the app-group suite so the share extension can
    // read it; SharedStore falls back to .standard when no group exists.
    @AppStorage("serverURL", store: SharedStore.defaults) private var serverURL = ""
    @AppStorage("gridSize") private var gridSizeRaw = GridSize.medium.rawValue
    @State private var bearerToken = KeychainStore.loadToken() ?? ""
    @State private var testStatus: String?
    @State private var isTesting = false
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        Form {
            Section("Server") {
                TextField("URL", text: $serverURL, prompt: Text("https://gif.example.com"))
                    .textContentType(.URL)
                SecureField("API Token", text: $bearerToken, prompt: Text("Paste your API token"))
                    .onChange(of: bearerToken) { _, newValue in
                        KeychainStore.saveToken(newValue)
                    }
            }

            Section("Appearance") {
                Picker("GIF Size", selection: $gridSizeRaw) {
                    ForEach(GridSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(serverURL.isEmpty || bearerToken.isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let status = testStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.starts(with: "OK") ? .green : .red)
                    }

                    Spacer()

                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                // On iOS, default-styled buttons in a Form row share one tap
                // target — tapping "Test Connection" would also fire "Done"
                // and dismiss the sheet. Borderless gives each its own hit area.
                #if os(iOS)
                .buttonStyle(.borderless)
                #endif
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 400, height: 280)
        #endif
    }

    private func testConnection() {
        guard let url = APIClient.validateBaseURL(serverURL) else {
            testStatus = URL(string: serverURL) != nil
                ? "URL must use https:// (http is allowed only for localhost)"
                : "Invalid URL"
            return
        }
        isTesting = true
        testStatus = nil
        let client = APIClient(baseURL: url, token: bearerToken)
        Task {
            do {
                let gifs = try await client.listGIFs()
                testStatus = "OK — \(gifs.count) GIFs"
            } catch {
                testStatus = error.localizedDescription
            }
            isTesting = false
        }
    }
}
