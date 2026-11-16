import CryptoKit
import Foundation
import OSLog
import SwiftSoup

/// Only complete locally extracted sources may be grouped in protocol v1. This avoids
/// slicing rich HTML or pretending model-selected character spans preserve its objects.
struct AIReflowEvidence: Sendable {
    struct Source: Sendable {
        let block: TextBlock
        let kind: AIReflowPlan.Kind
        let translates: Bool
        let parts: [Part]
        let objects: [Object]
        var objectIDs: [String] { objects.map(\.id) }
    }
    struct Part: Codable, Sendable {
        let type: String
        let text: String?
        let objectID: String?
        enum CodingKeys: String, CodingKey {
            case type, text
            case objectID = "object_id"
        }
    }
    struct Object: Sendable {
        let id: String
        let marker: String?
        let html: String
        let description: String
    }
    let sources: [Source]
    let digest: String

    func wireID(_ id: UUID) -> String {
        guard let index = sources.firstIndex(where: { $0.block.id == id }) else { return id.uuidString }
        return "s\(index)"
    }

    func sourceID(_ wireID: String) -> UUID? {
        if wireID.hasPrefix("s"), let index = Int(wireID.dropFirst()), wireID == "s\(index)",
            sources.indices.contains(index)
        {
            return sources[index].block.id
        }
        return UUID(uuidString: wireID)
    }

    init(_ blocks: [TextBlock]) throws {
        guard !blocks.isEmpty, blocks.count <= 128, Set(blocks.map(\.id)).count == blocks.count else {
            throw ReaderError.message("重排窗口为空、重复或过大，请重新准备资料。")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        digest = Self.hash(try encoder.encode(blocks))
        sources = try blocks.map(Self.source)
        guard sources.reduce(0, { $0 + $1.block.text.utf8.count }) <= 100_000 else {
            throw ReaderError.message("重排窗口文字过多，请缩小处理范围。")
        }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func configurationDigest(_ settings: ModelSettings) throws -> String {
        let normalized = try settings.normalized()
        return hash(
            Data(
                "v1\n\(try normalized.endpointURL().absoluteString)\n\(normalized.model)\n\(normalized.temperature)"
                    .utf8))
    }

    private static func source(_ block: TextBlock) throws -> Source {
        let rich = block.richContent
        let doc = try SwiftSoup.parseBodyFragment(rich?.html ?? "")
        let translates = rich?.requiresTranslation ?? !block.text.isEmpty
        let kind: AIReflowPlan.Kind
        if try !doc.select("table").isEmpty() {
            kind = .table
        } else if try !doc.select("pre,code,.ltx_listing").isEmpty(), !translates {
            kind = .code
        } else if try !doc.select(".ltx_biblist,.bibliography").isEmpty() {
            kind = .bibliography
        } else if try !doc.select(".ltx_authors,.front-matter").isEmpty() {
            kind = .frontMatter
        } else if rich?.isFigure == true {
            kind = translates ? .figureCaption : .figure
        } else if try !doc.select("h1").isEmpty() {
            kind = .title
        } else if try !doc.select("h2,h3,h4,h5,h6").isEmpty() {
            kind = .heading
        } else if try !doc.select("ul,ol,li").isEmpty() {
            kind = .listItem
        } else if !translates {
            kind =
                try doc.select("math,.ltx_equation,.ltx_equationgroup").isEmpty() ? .preservedSource : .displayFormula
        } else {
            kind = .paragraph
        }
        // These locally known categories always preserve their original contents.
        let shouldTranslate =
            translates && ![.table, .code, .bibliography, .frontMatter, .nonContent, .preservedSource].contains(kind)
        let input = shouldTranslate ? (rich?.translationInput ?? block.text) : ""
        var objects: [Object] = []
        var parts: [Part] = []
        var remaining = input[...]
        let markers = (rich?.mathematics.keys.map { $0 } ?? []).sorted()
        for (index, marker) in markers.enumerated() {
            objects.append(
                Object(
                    id: "math_\(block.id.uuidString)_\(index)", marker: marker,
                    html: rich?.mathematics[marker] ?? "", description: rich?.mathDescriptions[marker] ?? ""))
        }
        while !remaining.isEmpty {
            let next = objects.compactMap { object -> (Object, Range<String.Index>)? in
                guard let marker = object.marker, let range = remaining.range(of: marker) else { return nil }
                return (object, range)
            }.min { $0.1.lowerBound < $1.1.lowerBound }
            guard let (object, range) = next else {
                parts.append(Part(type: "text", text: String(remaining), objectID: nil))
                break
            }
            if range.lowerBound > remaining.startIndex {
                parts.append(Part(type: "text", text: String(remaining[..<range.lowerBound]), objectID: nil))
            }
            parts.append(Part(type: "object_ref", text: nil, objectID: object.id))
            remaining = remaining[range.upperBound...]
        }
        if shouldTranslate {
            try rich?.validate(input)
        }
        let containsSharedObject = try !doc.select("img,svg,table").isEmpty()
        if !shouldTranslate || rich?.isFigure == true || containsSharedObject {
            objects.append(
                Object(id: "source_\(block.id.uuidString)", marker: nil, html: rich?.html ?? "", description: "原始共享对象"))
        }
        return Source(block: block, kind: kind, translates: shouldTranslate, parts: parts, objects: objects)
    }

    func assemble(_ planned: AIReflowPlan.Block) throws -> (TextBlock, [String: String], Bool) {
        let selected = try planned.sourceIDs.map { id in
            guard let source = sources.first(where: { $0.block.id == id }) else { throw Self.invalid() }
            return source
        }
        guard let first = selected.first else { throw Self.invalid() }
        var result = first.block
        result.id = planned.id
        result.text = selected.map { $0.block.text }.joined(separator: " ")
        result.reflowProvenance = zip(planned.sourceSegments, selected).map { segment, source in
            AIReflowSourceSpan(
                sourceID: segment.sourceID, startUTF16: segment.startUTF16,
                endUTF16: segment.endUTF16, sourcePage: source.block.sourcePage, texSource: source.block.texSource)
        }
        // A legacy single-page citation cannot truthfully describe a cross-page paragraph.
        result.sourcePage = Set(selected.map { $0.block.sourcePage }).count == 1 ? first.block.sourcePage : -1
        var mathematics: [String: String] = [:]
        var descriptions: [String: String] = [:]
        var objectMarkers: [String: String] = [:]
        var inputParts: [String] = []
        for source in selected {
            var input = source.translates ? (source.block.richContent?.translationInput ?? source.block.text) : ""
            // Replace markers through unique temporary tokens to prevent collisions (MATH_1/MATH_10).
            for object in source.objects where object.marker != nil {
                guard let old = object.marker else { continue }
                let marker = "[[MATH_\(mathematics.count + 1)]]"
                let temporary = "[[REF_\(object.id)]]"
                input = input.replacingOccurrences(of: old, with: temporary)
                mathematics[marker] = object.html
                descriptions[marker] = object.description
                objectMarkers[object.id] = marker
            }
            for (objectID, marker) in objectMarkers {
                input = input.replacingOccurrences(of: "[[REF_\(objectID)]]", with: marker)
            }
            inputParts.append(input)
        }
        let excluded = [.frontMatter, .nonContent].contains(planned.kind)
        let translates =
            selected.contains(where: \.translates)
            && !excluded && ![.bibliography, .code].contains(planned.kind)
        if selected.count > 1 || first.block.richContent != nil {
            let html = selected.map { $0.block.richContent?.html ?? "<p>\(Self.escape($0.block.text))</p>" }.joined(
                separator: "\n")
            var rich =
                first.block.richContent
                ?? RichContent(html: html, translationInput: "", mathematics: [:], mathDescriptions: [:])
            rich.html = html
            rich.translationInput = translates ? inputParts.joined(separator: " ") : ""
            rich.mathematics = mathematics
            rich.mathDescriptions = descriptions
            result.richContent = rich
        } else if !translates {
            result.richContent = RichContent(
                html: "<p>\(Self.escape(result.text))</p>", translationInput: "", mathematics: [:],
                mathDescriptions: [:])
        }
        // Model classification selects only an application-owned heading template.
        // Existing trusted markup/anchors remain intact; model HTML is never accepted.
        if selected.count == 1, first.kind == .paragraph, [.title, .heading].contains(planned.kind) {
            let tag = planned.kind == .title ? "h1" : "h2"
            let document = try SwiftSoup.parseBodyFragment(
                result.richContent?.html ?? "<p>\(Self.escape(result.text))</p>")
            if let paragraph = try document.select("p").first() { try paragraph.tagName(tag) }
            if result.richContent == nil {
                result.richContent = RichContent(
                    html: try document.body()?.html() ?? "", translationInput: result.text, mathematics: [:],
                    mathDescriptions: [:])
            } else {
                result.richContent?.html = try document.body()?.html() ?? ""
            }
        }
        result.imageWarnings = selected.flatMap { $0.block.imageWarnings ?? [] }
        result.hasImageFailure = selected.contains { $0.block.hasImageFailure == true }
        result.excludedFromReading = excluded ? true : nil
        return (result, objectMarkers, translates)
    }

    static func validateTranslation(_ translation: String, for block: TextBlock) throws {
        // Catch only model-output validation, never a storage/publication callback.
        // These errors must enter the same bounded recovery path as malformed events.
        let content =
            block.richContent
            ?? RichContent(html: "", translationInput: block.text, mathematics: [:], mathDescriptions: [:])
        do {
            try content.validate(translation)
        } catch {
            Logger(subsystem: "dev.paperreader", category: "ReflowValidation")
                .error(
                    "Translation formula validation rejected; expected markers=\(block.richContent?.mathematics.count ?? 0)"
                )
            throw invalid()
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    static func invalid(file: String = #fileID, line: Int = #line) -> AIReflowFailure {
        Logger(subsystem: "dev.paperreader", category: "ReflowValidation")
            .error("Rejected reflow at \(file, privacy: .public):\(line)")
        return .invalidStructure
    }
}
