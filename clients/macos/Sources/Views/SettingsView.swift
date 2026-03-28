import SwiftUI

struct SettingsView: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("bearerToken") private var bearerToken = ""
    @State private var testStatus: String?
    @State private var isTesting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Server") {
                TextField("URL", text: $serverURL, prompt: Text("https://gif.example.com"))
                    .textContentType(.URL)
                SecureField("Bearer Token", text: $bearerToken, prompt: Text("Paste your API token"))
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
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 200)
    }

    private func testConnection() {
        guard let url = URL(string: serverURL) else {
            testStatus = "Invalid URL"
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
