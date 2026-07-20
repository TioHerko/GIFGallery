import Foundation

public struct GIFItem: Codable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public let url: String
    public let thumbnailUrl: String?
    public let embedUrl: String
    public var tags: [Tag]
    public var copyCount: Int
    public let createdAt: String

    public var displayUrl: String { thumbnailUrl ?? url }
}

public struct GIFListResponse: Codable {
    public let gifs: [GIFItem]
}

public struct CopyResponse: Codable {
    public let copyCount: Int
}

public struct DeleteResponse: Codable {
    public let deleted: Bool
}

public struct UploadResponse: Codable {
    public let created: [String]
}

public struct UploadErrorResponse: Codable {
    public let errors: [String]
}

/// Errors surfaced by APIClient with a user-readable message.
public enum APIError: LocalizedError {
    case upload(String)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .upload(let message): message
        case .http(let status): "Upload failed (HTTP \(status))."
        }
    }
}

public struct RenameResponse: Codable {
    public let title: String
}

/// Upload limits reported by `GET /api/config/`, so clients can validate
/// before sending (e.g. reject an over-long video without uploading it).
public struct ServerConfig: Codable, Sendable {
    public let videoMaxDurationSeconds: Double
    public let videoMaxWidth: Int
    public let maxUploadBytes: Int
    public let videoExtensions: [String]
}
