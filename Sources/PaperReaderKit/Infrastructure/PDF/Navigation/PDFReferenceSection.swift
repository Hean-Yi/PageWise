import Foundation
import PDFKit
import Synchronization

/// References remain source text. Their author initials, title, year and venue belong to one entry
/// even when a sentence tokenizer would split them or a PDF column ends in the middle of the entry.
extension PDFSentenceExtractor {
    struct ReferenceSection {
        let label: String
        let lines: [Line]
        let entries: [String]
        let following: IndexSet
        let offsets: Set<Int>

        func bodyRows(in rows: [[Line]], source: NSString) -> [[Line]] {
            rows.compactMap { row in
                let body = row.filter { line in !line.runs.allSatisfy { offsets.contains($0.range.location) } }
                if body.count == 2, let first = body.first, let last = body.last,
                    content(first, source: source).wholeMatch(of: /[A-Z](?:\.[0-9]+)*\.?/) != nil,
                    last.bounds.minX - first.bounds.maxX <= first.bounds.height * 3,
                    endOfReferences(content(first, source: source) + " " + content(last, source: source))
                {
                    return [Line(runs: first.runs + last.runs, bounds: first.bounds.union(last.bounds))]
                }
                return body.isEmpty ? nil : body
            }
        }

        func item(pageIndex: Int, sentences: [PDFSourceSentence]) -> PDFReadingIllustration? {
            guard let first = lines.first?.runs.first, !entries.isEmpty else { return nil }
            let next = sentences.first { sentence in
                sentence.characterRanges.contains { following.intersects(integersIn: $0.location..<NSMaxRange($0)) }
            }
            return PDFReadingIllustration(
                id: "p\(pageIndex)-refs-\(first.range.location)", label: label, pageIndex: pageIndex,
                sourceBounds: lines.reduce(CGRect.null) { $0.union($1.bounds) },
                insertBeforeSentenceID: next?.id, imagePNG: nil,
                originalText: .init(kind: .references, paragraphs: entries))
        }
    }

    static func referenceSection(
        rows: [[Line]], source: NSString, document: PDFDocument, pageIndex: Int, crop: CGRect, spellings: Set<String>,
        captionRegions: () throws -> [PDFCaptionRegion]
    ) throws -> ReferenceSection? {
        let raw = rows.flatMap { $0 }
        let labels = raw.map { content($0, source: source) }
        let hasHeading = labels.contains(where: referenceHeading)
        if !hasHeading {
            // A body page citing other authors may contain years and publication names. Require an
            // actual preceding section heading as well as bibliography evidence on this very page.
            guard pageIndex > 0, hasCitationEvidence(labels),
                try followsReferenceHeading(document: document, pageIndex: pageIndex)
            else { return nil }
        }
        let adjacentTop = [pageIndex - 1, pageIndex + 1].compactMap { index -> String? in
            guard (0..<document.pageCount).contains(index) else { return nil }
            return document.page(at: index)?.string.map { String($0.prefix(400)) }
        }
        let captions = try captionRegions()
        var marginOffsets = Set<Int>()
        let cleaned = rows.compactMap { row -> [Line]? in
            var lines = [Line]()
            for line in row {
                let text = content(line, source: source)
                if captions.contains(where: { region in
                    line.runs.allSatisfy { run in
                        region.sourceBounds?.insetBy(dx: -1, dy: -1).contains(run.bounds) == true
                            || NSIntersectionRange(run.range, region.captionRange).length > 0
                    }
                }) {
                    continue
                }
                if line.bounds.midY < crop.minY + crop.height * 0.12, row.count == 1, Int(text) != nil { continue }
                if line.bounds.midY > crop.maxY - crop.height * 0.105, text.count >= 8, !referenceHeading(text),
                    adjacentTop.contains(where: { $0.contains(text) })
                {
                    marginOffsets.formUnion(line.runs.map(\.range.location))
                    continue
                }
                // In numbered lists the marker often has its own PDF text run, separated by a tab stop.
                if let last = lines.last, referenceNumber(content(last, source: source))?.remainder.isEmpty == true,
                    line.bounds.minX - last.bounds.maxX < max(32, line.bounds.height * 3)
                {
                    lines[lines.count - 1].runs += line.runs
                    lines[lines.count - 1].bounds = last.bounds.union(line.bounds)
                } else {
                    lines.append(line)
                }
            }
            return lines.isEmpty ? nil : lines
        }
        let cleanedLabels = cleaned.joined().map { content($0, source: source) }
        let titles = cleaned.flatMap { row in
            row.filter { line in
                let title = content(line, source: source)
                guard referenceHeading(title) else { return false }
                return title.lowercased() != "reference"
                    || !row.contains { peer in
                        peer.runs.first?.range != line.runs.first?.range
                            && shortHeaderPeer(
                                content(peer, source: source), bounds: peer.bounds, title: line.bounds,
                                width: crop.width)
                    }
            }
        }
        let titleOffsets = Set(titles.flatMap { $0.runs.map(\.range.location) })
        let sectionTitle = titles.first.map { content($0, source: source) }
        if hasHeading, sectionTitle == nil { return nil }
        if sectionTitle?.lowercased() == "reference", !hasCitationEvidence(cleanedLabels) { return nil }
        var skippedLines = false
        let bands = orderedColumns(rows: cleaned, crop: crop, joiningReferenceLines: true, omitted: &skippedLines)
        let ordered = bands.enumerated().flatMap { column, lines in
            lines.map { (column: column, line: $0, text: content($0, source: source)) }
        }
        let heading = ordered.firstIndex { item in
            referenceHeading(item.text) && item.line.runs.contains { titleOffsets.contains($0.range.location) }
        }
        if let title = sectionTitle {
            let earlyNumbers = ordered.prefix(heading ?? 0).compactMap { referenceNumber($0.text)?.value }
            let consecutive = zip(earlyNumbers, earlyNumbers.dropFirst()).filter { $1 == $0 + 1 }.count
            if heading == nil || consecutive >= 2 {
                // A verified list title with no trustworthy position (or numbered entries before
                // its title) indicates a crossed gutter. Keep the source page intact.
                return ReferenceSection(
                    label: title, lines: raw, entries: [], following: IndexSet(),
                    offsets: Set(raw.flatMap { $0.runs.map(\.range.location) }))
            }
        }
        let start = heading.map { $0 + 1 } ?? 0
        let end =
            ordered[start...].firstIndex { item in
                if endOfReferences(item.text) { return true }
                guard let first = item.line.runs.first, item.line.runs.count > 1, item.text.count < 90,
                    source.substring(with: first.range).wholeMatch(of: /[A-Z](?:\.[0-9]+)*\.?/) != nil
                else { return false }
                let gap = item.line.runs[1].bounds.minX - first.bounds.maxX
                return gap > first.bounds.height * 0.8 && item.text.last != "." && !item.text.contains(",")
            } ?? ordered.endIndex
        guard heading != nil || start < end else { return nil }
        let entries = ordered[start..<end]
        var lines = ordered[(heading ?? start)..<end].map(\.line)
        let after = ordered[end...].map(\.line)
        // If ordering discarded a row within the reference region, preserve the original region
        // instead of publishing an entry whose authors or title may be incomplete.
        var verified = true
        if skippedLines {
            let placed = Set(ordered.flatMap { $0.line.runs.map(\.range.location) })
            let envelopes = Dictionary(grouping: entries, by: \.column).values.map { lane in
                lane.reduce(CGRect.null) { $0.union($1.line.bounds) }.insetBy(dx: -1, dy: -3)
            }
            for line in cleaned.joined() where !line.runs.allSatisfy({ placed.contains($0.range.location) }) {
                if envelopes.contains(where: { $0.intersects(line.bounds) }) || (heading == 0 && end == ordered.count) {
                    lines.append(line)
                    verified = false
                }
            }
        }
        var following = IndexSet()
        for run in after.flatMap(\.runs) { following.insert(integersIn: run.range.location..<NSMaxRange(run.range)) }
        if let last = entries.last {
            let lane = entries.filter { $0.column == last.column }.reduce(CGRect.null) { $0.union($1.line.bounds) }
            for caption in captions {
                let bounds = caption.captionBounds
                let nextColumn = lane.maxX < crop.midX + crop.width * 0.04 && bounds.minX > lane.maxX
                let below = bounds.midY < last.line.bounds.minY && bounds.maxX > lane.minX && bounds.minX < lane.maxX
                if nextColumn || below {
                    let range = caption.captionRange
                    following.insert(integersIn: range.location..<NSMaxRange(range))
                }
            }
        }
        return ReferenceSection(
            label: heading.map { ordered[$0].text } ?? "", lines: lines,
            entries: verified ? referenceEntries(Array(entries), spellings: spellings) : [],
            following: following, offsets: marginOffsets.union(lines.flatMap { $0.runs.map(\.range.location) }))
    }

    private static func shortHeaderPeer(_ text: String, bounds: CGRect, title: CGRect, width: CGFloat) -> Bool {
        text.count < 36 && abs(bounds.midY - title.midY) < title.height * 0.4
            && abs(bounds.midX - title.midX) < width * 0.45
    }

    private static func referenceHeading(_ text: String) -> Bool {
        let label = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count < 35 else { return false }
        return label.wholeMatch(
            of:
                /(?:(?:[0-9]+(?:\.[0-9]+)*|[ivx]+)[.)]?\s+)?(?:references?|bibliography|works cited|literature cited)[:.]?/
        ) != nil
            || ["references", "bibliography"].contains(label.filter { !$0.isWhitespace })
    }

    static func endOfReferences(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count < 100 else { return false }
        let lower = t.lowercased()
        if lower.wholeMatch(
            of:
                /(?:appendix|appendices|supplementary (?:material|information)|acknowledg[e]?ments|author contributions)(?:[.:]?\s+[a-z0-9](?:[.:]?\s+.{1,65})?)?[:.]?/
        ) != nil {
            return true
        }
        // Lettered appendix sections have no comma-separated authors or sentence punctuation.
        guard t.wholeMatch(of: /[A-Z](?:\.[0-9]+)*\.?\s+[A-Z][\p{L}\p{N}\s-]{2,68}/) != nil else { return false }
        return t.firstMatch(
            of:
                /(?i)\b(?:appendix|settings|benchmarks?|details|experiments?|results?|implementation|proofs?|analysis|derivation|setup|evaluation|training|methodology|examples?|hyperparameters|datasets?|limitations?|materials?)\b/
        ) != nil
    }

    private struct SourceRevision: Hashable {
        let url: URL
        let date: Date
        let size: Int

        init?(document: PDFDocument) {
            guard let url = document.documentURL,
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                let date = values.contentModificationDate, let size = values.fileSize
            else { return nil }
            self.url = url
            self.date = date
            self.size = size
        }
    }

    // Pages can be requested out of order, by the reader and the queue concurrently. Cache only
    // whether the source was inside a bibliography at a page boundary, never PDFKit objects.
    private static let boundaryCache = Mutex<[SourceRevision: [Int: Bool]]>([:])

    private static func followsReferenceHeading(document: PDFDocument, pageIndex: Int) throws -> Bool {
        let revision = SourceRevision(document: document)
        let known = revision.flatMap { key in boundaryCache.withLock { $0[key] } }
        var visited = [Int]()
        var references = false
        scan: for index in (0..<pageIndex).reversed() {
            try Task.checkCancellation()
            if let value = known?[index] {
                references = value
                break
            }
            guard let page = document.page(at: index), page.numberOfCharacters <= 70_000, let text = page.string else {
                break
            }
            visited.append(index)
            let lines = text.split(whereSeparator: \.isNewline)
            for (position, row) in lines.enumerated().reversed() {
                let line = String(row)
                if referenceHeading(line) {
                    let range = NSRange(row.startIndex..<row.endIndex, in: text)
                    guard let box = page.selection(for: range)?.bounds(for: page),
                        try !PDFCaptionRegionDetector.regions(on: page).contains(where: { region in
                            region.sourceBounds?.insetBy(dx: -1, dy: -1).contains(box) == true
                        })
                    else { continue }
                    if line.trimmingCharacters(in: .whitespaces).lowercased() == "reference" {
                        let later = lines.dropFirst(position + 1)
                        guard hasCitationEvidence(later.map(String.init)) else { continue }
                        // In a borderless comparison table PDFKit may place each column label on
                        // its own string line. A short neighbouring cell on the same baseline
                        // distinguishes that header from a stand-alone bibliography title.
                        let peers = lines[max(0, position - 2)..<min(lines.count, position + 3)]
                        let alongside = peers.contains { peer in
                            guard peer.startIndex != row.startIndex, peer.count < 36,
                                let rect = page.selection(for: NSRange(peer.startIndex..<peer.endIndex, in: text))?
                                    .bounds(for: page)
                            else { return false }
                            return shortHeaderPeer(
                                String(peer), bounds: rect, title: box, width: page.bounds(for: .cropBox).width)
                        }
                        if alongside { continue }
                    }
                    references = true
                    break scan
                }
                if endOfReferences(line) { break scan }
            }
        }
        if let revision, !visited.isEmpty {
            boundaryCache.withLock { cache in
                if cache[revision] == nil, cache.count >= 12, let old = cache.keys.first { cache[old] = nil }
                for index in visited { cache[revision, default: [:]][index] = references }
            }
        }
        return references
    }

    private static func referenceNumber(_ text: String) -> (value: Int, remainder: Substring)? {
        guard let match = text.prefixMatch(of: /(?:\[([0-9]{1,4})\]|\(([0-9]{1,4})\)|([0-9]{1,3})[.)])(?:\s+|$)/),
            let number = match.1 ?? match.2 ?? match.3, let value = Int(number)
        else { return nil }
        return (value, text[match.range.upperBound...])
    }

    private static func hasCitationEvidence(_ lines: [String]) -> Bool {
        var years = 0
        var numbers = 0
        var citation = false
        for line in lines {
            if referenceNumber(line) != nil { numbers += 1 }
            if line.firstMatch(of: /\b(?:19|20)[0-9]{2}[a-z]?\b/) != nil { years += 1 }
            if line.firstMatch(of: /(?i)(?:doi[.:]|arxiv[:.]|proceedings of|journal of|https?:\/\/)/) != nil
                || line.firstMatch(
                    of:
                        /\b\p{Lu}[\p{L}'’-]*,\s+\p{Lu}\.|\b\p{Lu}\.\s+\p{Lu}[\p{L}'’-]+|\b\p{Lu}[\p{L}'’-]+\s+\p{Lu}[\p{L}'’-]+,/
                ) != nil
            {
                citation = true
            }
        }
        return numbers >= 2 || ((numbers > 0 || citation) && years > 0)
            || (citation && lines.count <= 6)
    }

    private typealias CitationLine = (column: Int, line: Line, text: String)

    private static func referenceEntries(_ lines: [CitationLine], spellings: Set<String>) -> [String] {
        guard !lines.isEmpty else { return [] }
        let numbers = lines.compactMap { referenceNumber($0.text)?.value }
        let enclosed = lines.contains {
            ($0.text.hasPrefix("[") || $0.text.hasPrefix("(")) && referenceNumber($0.text) != nil
        }
        let numbered =
            enclosed || zip(numbers, numbers.dropFirst()).contains { $1 == $0 + 1 }
            || lines.first.map { referenceNumber($0.text)?.value == 1 } == true
        // Repeated first and hanging indents are measured independently for each column.
        var margins = [Int: CGFloat]()
        for (column, lane) in Dictionary(grouping: lines, by: \.column) {
            let xs = lane.map(\.line.bounds.minX).sorted()
            let height = lane.map(\.line.bounds.height).sorted()[lane.count / 2]
            let tolerance = max(1.3, height * 0.16)
            guard let first = xs.first,
                xs.contains(where: { $0 - first > tolerance * 2 && $0 - first < height * 3 })
            else { continue }
            margins[column] = first + tolerance
        }
        var entries = [String]()
        for (i, current) in lines.enumerated() {
            let text = current.text
            if text.contains("\u{fffd}") { return [] }
            let starts: Bool
            if numbered {
                starts = (!enclosed || text.hasPrefix("[") || text.hasPrefix("(")) && referenceNumber(text) != nil
            } else if let margin = margins[current.column] {
                starts = current.line.bounds.minX <= margin
            } else if i > 0 {
                let previous = lines[i - 1]
                let pitch = previous.line.bounds.midY - current.line.bounds.midY
                starts =
                    previous.column == current.column && pitch > current.line.bounds.height * 1.65
                    || (previous.text.last == "."
                        && text.firstMatch(of: /^\p{Lu}[\p{L}'’-]+,\s+\p{Lu}\.|^\p{Lu}\.\s+\p{Lu}[\p{L}'’-]+,/) != nil)
            } else {
                starts = true
            }
            if starts || entries.isEmpty {
                entries.append(text)
            } else {
                let last = entries.count - 1
                if !continuesLink(entries[last], next: text) {
                    switch PDFEnglishLineBreak.separator(after: entries[last], before: text, spellings: spellings) {
                    case .space: entries[last] += " "
                    case .removeHyphen: entries[last].removeLast()
                    case .joined: break
                    }
                }
                entries[last] += text
            }
        }
        // Dense blocks with no separable markers, hanging indents or entry spacing keep the
        // printed layout. Several publications must not turn into one apparent citation.
        if entries.count == 1, !numbered, margins.isEmpty, lines.count >= 6,
            lines.filter({ $0.text.firstMatch(of: /\b(?:19|20)[0-9]{2}[a-z]?\b/) != nil }).count >= 2
        {
            return []
        }
        return entries
    }

    private static func continuesLink(_ left: String, next: String) -> Bool {
        guard let token = left.split(whereSeparator: \.isWhitespace).last,
            let nextToken = next.split(whereSeparator: \.isWhitespace).first
        else { return false }
        if token == "https:" || token == "http:" { return nextToken.hasPrefix("//") }
        guard token.contains("://") || token.hasPrefix("10.") && token.contains("/") else { return false }
        return token.last.map { "/_-=?&#".contains($0) } == true || token.hasSuffix(".") && nextToken.contains("/")
    }
}
