import Foundation

struct Tag: Codable, Identifiable, Hashable {
    let name: String
    let slug: String

    var id: String { slug }
}

struct TagsResponse: Codable {
    let tags: [Tag]
}
