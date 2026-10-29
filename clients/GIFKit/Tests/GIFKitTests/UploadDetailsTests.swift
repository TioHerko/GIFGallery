import Foundation
import Testing
@testable import GIFKit

@MainActor
@Suite("UploadDetails")
struct UploadDetailsTests {
    // macOS writes a field's value back through its binding as soon as the
    // field takes focus, which used to make analyze() think the file was
    // already queued.
    @Test("a field writing back before analysis doesn't block it")
    func bindingWriteBeforeAnalyze() {
        let details = UploadDetails(isEnabled: true)
        let id = UUID()
        details.title(for: id).wrappedValue = ""
        details.analyze(id, filename: "x.gif", existingTags: []) { nil }
        #expect(details.entry(for: id).isAnalyzing)
        details.reset()
    }

    @Test("text typed before analysis survives queueing")
    func typedTitleSurvives() {
        let details = UploadDetails(isEnabled: true)
        let id = UUID()
        details.title(for: id).wrappedValue = "Mine"
        details.analyze(id, filename: "x.gif", existingTags: []) { nil }
        #expect(details.entry(for: id).title == "Mine")
        details.reset()
    }

    @Test("nothing is queued where the model is unavailable")
    func disabled() {
        let details = UploadDetails(isEnabled: false)
        let id = UUID()
        details.analyze(id, filename: "x.gif", existingTags: []) { nil }
        #expect(!details.entry(for: id).isAnalyzing)
    }
}
