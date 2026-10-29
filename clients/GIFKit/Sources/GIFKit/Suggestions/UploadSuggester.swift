import Foundation
import ImageIO
import os
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif
import Vision

/// `log stream --level debug --predicate 'category == "suggestions"'`
let suggestionLog = Logger(subsystem: "me.herko.gif", category: "suggestions")

/// A proposed title and tags for one file about to be uploaded.
public struct UploadSuggestion: Sendable, Equatable {
    public var title: String
    public var tags: [String]
}

/// Proposes a title and tags for media being uploaded from a Swift client,
/// using the on-device Foundation Models LLM over two cheap text sources:
/// the words in the filename and text OCR'd from a handful of frames.
///
/// Everything runs locally; the server only ever sees the result (applied
/// with the ordinary rename/tag calls). Returns nil wherever the model isn't
/// usable — before macOS/iOS 26, with Apple Intelligence off, or while the
/// model is still downloading — and when there's no text to go on, since a
/// text-only model would just invent something.
public enum UploadSuggester {
    /// Server limits: `Gif.title` and `Tag.name` max lengths.
    static let titleMaxLength = 200
    static let tagMaxLength = 100
    static let maxTags = 5

    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            let availability = SystemLanguageModel.default.availability
            if case .unavailable(let reason) = availability {
                suggestionLog.info("Model unavailable: \(String(describing: reason), privacy: .public)")
            }
            return availability == .available
        }
        #endif
        return false
    }

    /// `existingTags` are offered to the model so it reuses the library's
    /// vocabulary instead of coining near-duplicates.
    public static func suggest(data: Data, filename: String, existingTags: [String]) async -> UploadSuggestion? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, iOS 26, *), isAvailable else { return nil }
        let words = filenameWords(filename)
        let lines = await FrameText.recognize(in: data)
        suggestionLog.debug("""
            \(filename, privacy: .public): filename words \(words ?? "none", privacy: .public); \
            \(lines.count) OCR line(s): \(lines.joined(separator: " | "), privacy: .public)
            """)
        guard words != nil || !lines.isEmpty else {
            suggestionLog.info("\(filename, privacy: .public): no text to go on")
            return nil
        }
        guard let proposal = await Proposer.propose(
            filenameWords: words, frameText: lines, existingTags: existingTags)
        else { return nil }
        let suggestion = normalized(title: proposal.title, tags: proposal.tags)
        suggestionLog.info("""
            \(filename, privacy: .public): suggested \(suggestion?.title ?? "nothing", privacy: .public) \
            [\(suggestion?.tags.joined(separator: ", ") ?? "", privacy: .public)]
            """)
        return suggestion
        #else
        return nil
        #endif
    }

    /// Words worth showing the model from a filename, or nil when it's a
    /// generated name with nothing in it (`IMG_1234.gif`, `photo-3.gif`, a
    /// UUID, our own `shared.gif`).
    static func filenameWords(_ filename: String) -> String? {
        var stem = (filename as NSString).deletingPathExtension
        stem = stem.replacingOccurrences(of: "[_\\-.+]+", with: " ", options: .regularExpression)
        stem = stem.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        let words = stem.split(whereSeparator: \.isWhitespace).filter { word in
            let lower = word.lowercased()
            return lower.count(where: \.isLetter) >= 2
                && !generatedNameWords.contains(lower)
                && !looksLikeHash(lower)
        }
        guard words.contains(where: { $0.count(where: \.isLetter) >= 3 }) else { return nil }
        return words.joined(separator: " ")
    }

    /// Boilerplate from cameras, screen recorders, GIF sites and our own
    /// placeholder names.
    private static let generatedNameWords: Set<String> = [
        "img", "image", "photo", "pxl", "dsc", "mov", "vid", "video", "movie", "clip",
        "shared", "gif", "giphy", "tenor", "download", "downloaded", "untitled",
        "screen", "recording", "screenshot", "copy", "trim", "trimmed", "export", "edit",
    ]

    /// A UUID or hash fragment: hex digits only, with at least one digit.
    private static func looksLikeHash(_ word: String) -> Bool {
        word.count >= 6 && word.allSatisfy(\.isHexDigit) && word.contains(where: \.isNumber)
    }

    /// Tidies model output into something the server accepts: a single-line
    /// title within the length limit, and lowercase tags without commas
    /// (the API's tag separator), deduplicated.
    static func normalized(title: String, tags: [String]) -> UploadSuggestion? {
        func collapse(_ s: String) -> String {
            s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var cleanTitle = collapse(title).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        cleanTitle = String(cleanTitle.prefix(titleMaxLength))

        var seen = Set<String>()
        let cleanTags = tags
            .map { String(collapse($0.replacingOccurrences(of: ",", with: " ")).lowercased().prefix(tagMaxLength)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(maxTags)

        guard !cleanTitle.isEmpty || !cleanTags.isEmpty else { return nil }
        return UploadSuggestion(title: cleanTitle, tags: Array(cleanTags))
    }
}

/// Text found in a few frames spread across the clip.
@available(macOS 26, iOS 26, *)
enum FrameText {
    static let maxFrames = 6
    static let minConfidence: Float = 0.3

    /// Distinct lines of text, in the order first seen. Captions usually
    /// persist across frames, so duplicates are dropped.
    static func recognize(in data: Data) async -> [String] {
        let frames = UploadMedia.isGIF(data) ? gifFrames(data) : await videoFrames(data)
        suggestionLog.debug("OCR over \(frames.count) frame(s) of \(data.count) bytes")
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        var seen = Set<String>()
        var lines: [String] = []
        for frame in frames {
            guard let observations = try? await request.perform(on: frame) else { continue }
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence >= minConfidence
                else { continue }
                let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty, seen.insert(line.lowercased()).inserted {
                    lines.append(line)
                }
            }
        }
        return lines
    }

    private static func sampleIndices(count: Int) -> [Int] {
        guard count > maxFrames else { return Array(0..<count) }
        return (0..<maxFrames).map { $0 * (count - 1) / (maxFrames - 1) }
    }

    private static func gifFrames(_ data: Data) -> [CGImage] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        return sampleIndices(count: CGImageSourceGetCount(source)).compactMap {
            CGImageSourceCreateImageAtIndex(source, $0, nil)
        }
    }

    /// AVFoundation reads from URLs, so the clip goes through a temp file.
    private static func videoFrames(_ data: Data) async -> [CGImage] {
        #if canImport(AVFoundation)
        guard let described = UploadMedia.describe(data), described.contentType.hasPrefix("video/")
        else { return [] }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-ocr-\(UUID().uuidString).\(described.ext)")
        guard (try? data.write(to: tmp)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let asset = AVURLAsset(url: tmp)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)

        var frames: [CGImage] = []
        for i in 0..<maxFrames {
            // Midpoints of equal slices, so neither the first nor the last
            // (often black) frame is used.
            let seconds = duration.seconds * (Double(i) + 0.5) / Double(maxFrames)
            if let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                frames.append(frame)
            }
        }
        return frames
        #else
        return []
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
struct Proposal {
    @Guide(description: "A short, natural title for the GIF, usually 2 to 6 words. Use its caption or quote when it has one.")
    var title: String

    @Guide(description: "Lowercase keywords someone might search for to find this GIF.", .maximumCount(5))
    var tags: [String]
}

@available(macOS 26, iOS 26, *)
enum Proposer {
    /// Caps that keep the prompt well inside the model's context window.
    static let maxFrameTextCharacters = 1000
    static let maxExistingTags = 150

    static let instructions = """
        You title and tag GIFs for a personal GIF library. You get words from the \
        file's name and/or text read from its frames by OCR, which may contain \
        recognition errors or fragments. Propose a title and a few search keywords \
        based only on that text; don't invent details it doesn't support. When an \
        existing tag fits, use it exactly as written instead of a new variant.
        """

    static func propose(filenameWords: String?, frameText: [String], existingTags: [String]) async -> Proposal? {
        var prompt = ""
        if let filenameWords {
            prompt += "Filename words: \(filenameWords)\n"
        }
        if !frameText.isEmpty {
            prompt += "Text in the frames:\n\(String(frameText.joined(separator: "\n").prefix(maxFrameTextCharacters)))\n"
        }
        if !existingTags.isEmpty {
            prompt += "Existing tags: \(existingTags.prefix(maxExistingTags).joined(separator: ", "))\n"
        }

        let session = LanguageModelSession(instructions: instructions)
        // Guardrail hits (profanity is common in reaction GIFs), context
        // overflows and rate limits all just mean "no suggestion".
        do {
            return try await session.respond(to: prompt, generating: Proposal.self).content
        } catch {
            suggestionLog.error("Model declined or failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
#endif
