import Testing
@testable import GIFKit

@Suite("UploadSuggester")
struct UploadSuggesterTests {
    @Test("filename words are split on separators and camelCase")
    func filenameWordsSplit() {
        #expect(UploadSuggester.filenameWords("this_is-fine.gif") == "this is fine")
        #expect(UploadSuggester.filenameWords("MichaelScottNo.mp4") == "Michael Scott No")
    }

    @Test("generated names carry no words", arguments: [
        "IMG_1234.gif", "photo-3.gif", "shared.gif", "giphy.gif",
        "3f2a9c1b-77de-4c1a-9b1e-0a5d2c4e8f10.gif", "Screen Recording 2026-10-29 at 10.33.12.mov",
    ])
    func generatedNames(_ name: String) {
        #expect(UploadSuggester.filenameWords(name) == nil)
    }

    @Test("boilerplate is dropped but real words survive")
    func mixedNames() {
        #expect(UploadSuggester.filenameWords("giphy-dancing-cat-2.gif") == "dancing cat")
    }

    @Test("normalized output fits the server")
    func normalizedOutput() {
        let s = UploadSuggester.normalized(
            title: "  \"That's   What She Said\" ",
            tags: ["The Office", "the office", "funny, lol", " ", "a", "b", "c", "d"]
        )
        #expect(s?.title == "That's What She Said")
        #expect(s?.tags == ["the office", "funny lol", "a", "b", "c"])
    }

    @Test("empty model output is no suggestion")
    func emptyOutput() {
        #expect(UploadSuggester.normalized(title: "  ", tags: [""]) == nil)
    }
}
