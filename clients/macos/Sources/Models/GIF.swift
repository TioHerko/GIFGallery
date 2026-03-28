import Foundation

struct GIFItem: Codable, Identifiable {
    let id: String
    var title: String
    let url: String
    let embedUrl: String
    var tags: [Tag]
    var copyCount: Int
    let createdAt: String
}

struct GIFListResponse: Codable {
    let gifs: [GIFItem]
}

struct CopyResponse: Codable {
    let copyCount: Int
}

struct DeleteResponse: Codable {
    let deleted: Bool
}

struct UploadResponse: Codable {
    let created: [String]
}

struct RenameResponse: Codable {
    let title: String
}
