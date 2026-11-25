import Foundation
import SwiftSoup

extension HTMLReadingStore {
    /// Resolves an evidence quote against the published edition. Offsets use the same per-language
    /// DOM text nodes as HTMLSelectionScript; model-generated coordinates are never accepted.
    public func noteAnchors(
        for quote: String, evidence: Evidence, paperID: UUID, artifact: HTMLReadingArtifact, root: URL,
        selection: [NoteAnchor] = []
    ) throws -> [NoteAnchor] {
        try verifiedNote(
            for: quote, evidence: evidence, paperID: paperID, artifact: artifact, root: root,
            selection: selection
        ).anchors
    }

    private func verifiedNote(
        for quote: String, evidence: Evidence, paperID: UUID, artifact: HTMLReadingArtifact, root: URL,
        selection: [NoteAnchor]
    ) throws -> (anchors: [NoteAnchor], streams: [String: PublishedText]) {
        let unavailable = ReaderError.message("无法在这份阅读版本中核对引文，请选中对应原句。")
        let ambiguous = ReaderError.message("引文在原文中出现多次，请选中要标记的位置。")
        let words = quote.split(whereSeparator: \.isWhitespace)
        guard evidence.paperID == paperID, !words.isEmpty, quote.utf16.count <= 8_000,
            evidence.blockID != nil || !selection.isEmpty
        else { throw unavailable }
        let pattern = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        let expression = try NSRegularExpression(pattern: pattern)
        guard
            expression.firstMatch(in: evidence.text, range: NSRange(evidence.text.startIndex..., in: evidence.text))
                != nil
        else { throw unavailable }

        let positions = artifact.sections.indices.filter { index in
            let section = artifact.sections[index]
            return evidence.blockID.map { section.blockIDs.contains($0) }
                ?? selection.contains { $0.key == section.id.uuidString }
        }
        guard !positions.isEmpty else { throw unavailable }
        let keys = Set(positions.map { artifact.sections[$0].id.uuidString })
        let url = root.appendingPathComponent(artifact.relativePath)
        Self.retainOpenDocument(url)
        defer { Self.releaseOpenDocument(url) }
        try Task.checkCancellation()
        let sections = try verifiedSections.elements(
            at: url, paperID: paperID, artifact: artifact, positions: positions)
        var streams: [String: PublishedText] = [:]
        let citesEquation = evidence.text.hasPrefix("[公式] ")
        for element in sections {
            let key = try element.attr("data-key")
            guard keys.contains(key) else { continue }
            guard element.id() == "block-" + key, streams[key] == nil else { throw unavailable }
            streams[key] = try PublishedText(
                element: element, key: key,
                includesSelectedObjects: citesEquation
                    || selection.contains { $0.key == key && $0.target.hasPrefix("object:") }
                    || (evidence.blockID != nil && !(try element.select("table:not(.paper-equation)").isEmpty())))
        }
        guard streams.count == keys.count else { throw unavailable }

        let relevantSelection = evidence.blockID == nil ? selection : selection.filter { keys.contains($0.key) }
        if !relevantSelection.isEmpty {
            var selected: [AnchorFragment] = []
            for anchor in relevantSelection {
                guard let stream = streams[anchor.key], var fragments = stream.fragments(for: anchor) else {
                    throw unavailable
                }
                if let previous = selected.last, !fragments.isEmpty, previous.anchor.key != anchor.key {
                    fragments[0].boundary = .space
                }
                selected += fragments
            }
            let matches = try verifiedMatches(in: selected, expression: expression)
            if matches.count > 1 { throw ambiguous }
            if let match = matches.first { return (match, streams) }
        }
        guard evidence.blockID != nil else { throw unavailable }
        var matches: [[NoteAnchor]] = []
        for stream in streams.values {
            matches += try verifiedMatches(in: stream.source, expression: expression)
            let tables = stream.objects.filter { $0.text.hasPrefix("[表格] ") }
                .map { AnchorFragment(anchor: $0, boundary: .object) }
            matches += try verifiedMatches(in: tables, expression: expression)
            if citesEquation {
                let equations = stream.sourceEquations.filter { $0.text == evidence.text }
                    .map { AnchorFragment(anchor: $0, boundary: .object) }
                matches += try verifiedMatches(in: equations, expression: expression)
            }
            if matches.count > 1 { throw ambiguous }
        }
        guard let match = matches.first else { throw unavailable }
        return (match, streams)
    }

    /// The model receives exactly the prose runs the annotation verifier can locate.
    static func closeReadingSourceRuns(_ element: Element, key: String) throws -> [String] {
        let stream = try PublishedText(element: element, key: key, includesSelectedObjects: false)
        var runs: [String] = []
        var text = ""
        for fragment in stream.source {
            if fragment.boundary == .object {
                if !text.isEmpty { runs.append(text) }
                text = ""
            } else if fragment.boundary == .space, !text.isEmpty {
                text += " "
            }
            text += fragment.anchor.text
        }
        if !text.isEmpty { runs.append(text) }
        return runs
    }

    /// Read the expression preserved by the publisher or by the local TeX compiler.
    /// Flattened presentation MathML can lose fractions, exponents and operator grouping.
    static func publishedEquationSource(_ element: Element) throws -> String? {
        let alt = try element.attr("alttext")
        if !alt.isEmpty { return alt }
        guard let annotation = try element.select("annotation[encoding=application/x-tex]").first() else { return nil }
        let tex = objectTextNodes(annotation).joined()
        return tex.isEmpty ? nil : tex
    }
}

private func objectTextNodes(_ node: Node) -> [String] {
    if let text = node as? TextNode { return [text.getWholeText()] }
    return node.getChildNodes().flatMap(objectTextNodes)
}

private struct AnchorFragment {
    enum Boundary: Int { case joined, space, object }
    var anchor: NoteAnchor
    var boundary: Boundary

    func clipped(to interval: NSRange) -> Self? {
        let range = NSIntersectionRange(interval, NSRange(location: anchor.start, length: anchor.end - anchor.start))
        guard range.length > 0 else { return nil }
        let local = NSRange(location: range.location - anchor.start, length: range.length)
        var part = self
        part.anchor.text = (anchor.text as NSString).substring(with: local)
        part.anchor.start = range.location
        part.anchor.end = NSMaxRange(range)
        return part
    }
}

private struct PublishedText {
    var source: [AnchorFragment] = []
    var translation: [AnchorFragment] = []
    var objects: [NoteAnchor] = []
    var sourceEquations: [NoteAnchor] = []

    init(element: Element, key: String, includesSelectedObjects: Bool) throws {
        var boundary = [AnchorFragment.Boundary.joined, .joined]
        var offsets = [0, 0]
        func visit(_ node: Node, translated: Bool) throws {
            if let element = node as? Element {
                guard !element.hasClass("pending") else { return }
                let language = translated || element.hasClass("translation")
                let index = language ? 1 : 0
                let tag = element.tagName()
                // The selection script treats tables with only whitespace and no media as regular text.
                let sharedTable =
                    try tag == "table" && (!element.text().isEmpty || !element.select("img,svg,math").isEmpty())
                if sharedTable || ["img", "svg", "math"].contains(tag) || element.hasClass("paper-equation") {
                    if includesSelectedObjects {
                        let number = objects.count
                        let label = try Self.objectLabel(element, index: number)
                        let anchor = NoteAnchor(
                            key: key, target: "object:\(number)", text: label, start: 0, end: label.utf16.count)
                        objects.append(anchor)
                        if !language && label.hasPrefix("[公式] ") { sourceEquations.append(anchor) }
                    }
                    boundary[index] = .object
                    return
                }
                let separates = tag == "br" || element.isBlock()
                if separates && boundary[index] == .joined { boundary[index] = .space }
                for child in element.getChildNodes() { try visit(child, translated: language) }
                if separates && boundary[index] == .joined { boundary[index] = .space }
            } else if let node = node as? TextNode {
                let index = translated ? 1 : 0
                let text = node.getWholeText()
                guard !text.isEmpty else { return }
                let end = offsets[index] + text.utf16.count
                let anchor = NoteAnchor(
                    key: key, target: translated ? "translation" : "source", text: text, start: offsets[index], end: end
                )
                let part = AnchorFragment(anchor: anchor, boundary: boundary[index])
                if translated { translation.append(part) } else { source.append(part) }
                offsets[index] = end
                boundary[index] = .joined
            }
        }
        try visit(element, translated: false)
    }

    func fragments(for anchor: NoteAnchor) -> [AnchorFragment]? {
        if anchor.target.hasPrefix("object:") {
            guard objects.contains(anchor) else { return nil }
            return [AnchorFragment(anchor: anchor, boundary: .object)]
        }
        guard ["source", "translation"].contains(anchor.target), anchor.start >= 0, anchor.end > anchor.start,
            anchor.end - anchor.start == anchor.text.utf16.count
        else { return nil }
        let stream = anchor.target == "source" ? source : translation
        let range = NSRange(location: anchor.start, length: anchor.end - anchor.start)
        let fragments = stream.compactMap { $0.clipped(to: range) }
        guard fragments.map(\.anchor.text).joined().utf16.elementsEqual(anchor.text.utf16) else { return nil }
        return fragments
    }
    // Match the labels of whole objects produced by HTMLSelectionScript. DOM textContent
    // concatenates text nodes without the extra whitespace SwiftSoup's text() may introduce.
    private static func objectLabel(_ element: Element, index: Int) throws -> String {
        switch element.tagName() {
        case "img", "svg": return "[图片 \(index + 1)]"
        case "table" where !element.hasClass("paper-equation"):
            let children = Array(element.children())
            let direct = children.filter { ["tr", "tbody"].contains($0.tagName()) }
            let groups =
                children.filter { $0.tagName() == "thead" } + direct + children.filter { $0.tagName() == "tfoot" }
            let rows = groups.flatMap { $0.tagName() == "tr" ? [$0] : $0.children().filter { $0.tagName() == "tr" } }
            let lines = try rows.map { row in
                try row.children().filter { ["td", "th"].contains($0.tagName()) }.map { cell in
                    let value = objectTextNodes(cell).joined().split(whereSeparator: \.isWhitespace).joined(
                        separator: " ")
                    return try value.isEmpty && !cell.select("img,svg").isEmpty() ? "[图片]" : value
                }.joined(separator: "\t")
            }
            let caption = children.first { $0.tagName() == "caption" }
            return "[表格] "
                + (caption.map { objectTextNodes($0).joined().trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
                    ?? "")
                + lines.joined(separator: "\n")
        default:
            if let tex = try HTMLReadingStore.publishedEquationSource(element) { return "[公式] " + tex }
            return "[公式] "
                + objectTextNodes(element).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
        }
    }

}

/// The searchable copy includes visual line/paragraph breaks. The returned text always comes
/// from the original DOM nodes. Shared figures, tables and equations split independent runs.
private func verifiedMatches(in fragments: [AnchorFragment], expression: NSRegularExpression) throws -> [[NoteAnchor]] {
    var text = ""
    var runs: [(anchor: NoteAnchor, offset: Int)] = []
    var length = 0
    var matches: [[NoteAnchor]] = []
    func matchRun() {
        var start = 0
        while start < length, matches.count < 2,
            let match = expression.firstMatch(in: text, range: NSRange(location: start, length: length - start))
        {
            var anchors: [NoteAnchor] = []
            for (var anchor, offset) in runs {
                let overlap = NSIntersectionRange(
                    match.range, NSRange(location: offset, length: anchor.end - anchor.start))
                guard overlap.length > 0 else { continue }
                let local = NSRange(location: overlap.location - offset, length: overlap.length)
                anchor.text = (anchor.text as NSString).substring(with: local)
                anchor.start += local.location
                anchor.end = anchor.start + local.length
                if let last = anchors.last, last.key == anchor.key, last.target == anchor.target,
                    last.end == anchor.start
                {
                    anchors[anchors.count - 1].end = anchor.end
                    anchors[anchors.count - 1].text += anchor.text
                } else {
                    anchors.append(anchor)
                }
            }
            if !anchors.isEmpty { matches.append(anchors) }
            start = match.range.location + 1  // two overlapping occurrences are ambiguous as well
        }
    }
    for part in fragments {
        try Task.checkCancellation()
        if part.boundary == .object || part.anchor.target.hasPrefix("object:") {
            matchRun()
            if matches.count > 1 { return matches }
            text = ""
            runs.removeAll(keepingCapacity: true)
            length = 0
        } else if part.boundary == .space, !text.isEmpty {
            text += "\n"
            length += 1
        }
        if part.anchor.target.hasPrefix("object:") {
            let full = NSRange(part.anchor.text.startIndex..., in: part.anchor.text)
            if let hit = expression.firstMatch(in: part.anchor.text, range: full) {
                if hit.range == full {
                    matches.append([part.anchor])
                } else if part.anchor.text.hasPrefix("[表格] "), hit.range.location >= "[表格] ".utf16.count {
                    // Tables retain their original row and column structure as a single shared object.
                    // Repeated cell contents cannot identify which observation was cited.
                    matches.append([part.anchor])
                    let next = NSMaxRange(hit.range)
                    if next < full.length,
                        expression.firstMatch(
                            in: part.anchor.text,
                            range: NSRange(location: next, length: full.length - next)) != nil
                    {
                        matches.append([part.anchor])
                    }
                }
            }
            continue
        }
        runs.append((part.anchor, length))
        text += part.anchor.text
        length += part.anchor.end - part.anchor.start
    }
    matchRun()
    return matches
}

extension HTMLReadingStore {
    /// Reopen the very same published language stream. Its stable offsets disambiguate repeated wording.
    public func citationContext(for citation: LocalPassageCitation, artifact: HTMLReadingArtifact, root: URL) throws
        -> (before: String, after: String)
    {
        let failure = ReaderError.message("这处引用已无法在保存的阅读版本中核对。")
        let evidence = Evidence(id: "", title: "", text: citation.quote, paperID: citation.paperID)
        let (verified, streams) = try verifiedNote(
            for: citation.quote, evidence: evidence, paperID: citation.paperID,
            artifact: artifact, root: root, selection: citation.anchors)
        guard verified == citation.anchors, let first = verified.first, let last = verified.last else { throw failure }
        guard !first.target.hasPrefix("object:"), !last.target.hasPrefix("object:") else { return ("", "") }
        func text(for anchor: NoteAnchor) throws -> NSString {
            guard let stream = streams[anchor.key] else { throw failure }
            let parts = anchor.target == "source" ? stream.source : stream.translation
            let value = parts.map(\.anchor.text).joined() as NSString
            guard anchor.start >= 0, anchor.end > anchor.start, anchor.end <= value.length,
                value.substring(with: NSRange(location: anchor.start, length: anchor.end - anchor.start)) == anchor.text
            else { throw failure }
            return value
        }
        let startText = try text(for: first)
        let endText = first.key == last.key && first.target == last.target ? startText : try text(for: last)
        return (
            String(startText.substring(to: first.start).suffix(120)),
            String(endText.substring(from: last.end).prefix(180))
        )
    }
}
