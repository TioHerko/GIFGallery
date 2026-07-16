import Foundation

public struct Tag: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let slug: String

    public var id: String { slug }
}

public struct TagsResponse: Codable {
    public let tags: [Tag]
}
