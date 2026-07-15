import SwiftUI

struct SettingsView: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("gridSize") private var gridSizeRaw = GridSize.medium.rawValue
    @State private var bearerToken = KeychainStore.loadToken() ?? ""
    @State private var testStatus: String?
    @State private var isTesting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Server") {
                TextField("URL", text: $serverURL, prompt: Text("https://gif.example.com"))
                    .textContentType(.URL)
                SecureField("Bearer Token", text: $bearerToken, prompt: Text("Paste your API token"))
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 280)
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
