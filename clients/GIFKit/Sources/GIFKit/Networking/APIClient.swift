import Foundation

public struct APIClient: Sendable {
    public let baseURL: URL
    public let token: String

    /// Replaces the default URLCache (a few MB of disk) with one big enough
    /// to keep GIF previews across launches. The server marks GIFs and
    /// thumbnails `Cache-Control: public, max-age=31536000, immutable`, so
    /// cached entries never need revalidation. Call once at app startup.
    public static func installPersistentCache(
        memoryBytes: Int = 32 * 1024 * 1024,
        diskBytes: Int = 512 * 1024 * 1024
    ) {
        URLCache.shared = URLCache(memoryCapacity: memoryBytes, diskCapacity: diskBytes)
    }

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// Accepts only https base URLs — the bearer token rides in a header on
    /// every request, so plain http would put it on the wire in cleartext.
    /// Loopback hosts may use http for local development.
    public static func validateBaseURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { return nil }
        if scheme == "https" { return url }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        return (scheme == "http" && isLoopback) ? url : nil
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private func request(_ path: String, query: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func postForm(_ path: String, fields: [String: String]) -> URLRequest {
        var req = request(path)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        return req
    }

    // MARK: - Endpoints

    public func listGIFs(tag: String? = nil, query: String? = nil) async throws -> [GIFItem] {
        var params: [String: String] = [:]
        if let tag, !tag.isEmpty { params["tag"] = tag }
        if let query, !query.isEmpty { params["q"] = query }
        let req = request("api/gifs/", query: params)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try decoder.decode(GIFListResponse.self, from: data).gifs
    }

    @discardableResult
    public func trackCopy(id: String) async throws -> Int {
        let req = postForm("gif/\(id)/copy/", fields: [:])
        let (data, _) = try await URLSession.shared.data(for: req)
        return try decoder.decode(CopyResponse.self, from: data).copyCount
    }

    public func updateTags(id: String, tags: String) async throws -> [Tag] {
        let req = postForm("gif/\(id)/tags/", fields: ["tags": tags])
        let (data, _) = try await URLSession.shared.data(for: req)
        return try decoder.decode(TagsResponse.self, from: data).tags
    }

    public func rename(id: String, title: String) async throws -> String {
        let req = postForm("gif/\(id)/rename/", fields: ["title": title])
        let (data, _) = try await URLSession.shared.data(for: req)
        return try decoder.decode(RenameResponse.self, from: data).title
    }

    public func delete(id: String) async throws {
        let req = postForm("gif/\(id)/delete/", fields: [:])
        let _ = try await URLSession.shared.data(for: req)
    }

    public func upload(files: [URL], tags: String, titlePrefix: String) async throws -> [String] {
        let payloads = try files.map {
            SharePayload(filename: $0.lastPathComponent, data: try Data(contentsOf: $0))
        }
        return try await upload(payloads: payloads, tags: tags, titlePrefix: titlePrefix)
    }

    public func upload(payloads: [SharePayload], tags: String, titlePrefix: String) async throws -> [String] {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = request("upload/")
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        if !tags.isEmpty { appendField("tags", tags) }
        if !titlePrefix.isEmpty { appendField("title_prefix", titlePrefix) }

        for payload in payloads {
            // Filenames come from user-chosen files; quotes and CR/LF would
            // corrupt or inject multipart headers.
            let filename = payload.filename
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\"", with: "'")
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/gif\r\n\r\n".data(using: .utf8)!)
            body.append(payload.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, _) = try await URLSession.shared.data(for: req)
        return try decoder.decode(UploadResponse.self, from: data).created
    }

    public func fetchGIFData(from url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
