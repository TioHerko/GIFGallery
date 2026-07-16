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

public struct RenameResponse: Codable {
    public let title: String
}
