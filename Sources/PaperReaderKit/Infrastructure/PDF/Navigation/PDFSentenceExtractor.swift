import Foundation
import NaturalLanguage
import PDFKit

public enum PDFSentenceExtractor {
    public static func extract(url: URL, pageIndex: Int) throws -> [PDFSourceSentence] {
        let result = try extractPage(url: url, pageIndex: pageIndex)
        guard !result.sentences.isEmpty else { throw ReaderError.message(result.notice ?? "本页没有可译文字。") }
        return result.sentences
    }

    /// PDFKit objects stay inside this call. The UI can run extraction off the main actor.
    public static func extractPage(url: URL, pageIndex: Int) throws -> PDFSentenceExtraction {
        guard let document = PDFDocument(url: url), !document.isLocked,
            (0..<document.pageCount).contains(pageIndex), let page = document.page(at: pageIndex)
        else { throw ReaderError.message("无法读取原始 PDF 的这一页。") }
        defer { withExtendedLifetime(document) {} }
        let empty = PDFSentenceExtraction(sentences: [], notice: "本页没有可提取的正文，请查看原页。")
        let uncertain = PDFSentenceExtraction(sentences: [], notice: "本页文字位置或分栏顺序无法可靠核对，请查看原页或手动选译。")
        guard let string = page.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return empty
        }
        let source = string as NSString
        guard source.length == page.numberOfCharacters, source.length <= 70_000, page.rotation % 360 == 0,
            let selection = page.selection(for: NSRange(location: 0, length: source.length))
        else { return uncertain }

        var omitted = false
        var runs = [Run]()
        let crop = page.bounds(for: .cropBox)
        var seen = IndexSet()
        for line in selection.selectionsByLine() {
            try Task.checkCancellation()
            for index in 0..<line.numberOfTextRanges(on: page) {
                let range = line.range(at: index, on: page)
                guard range.location >= 0, range.location != NSNotFound, range.length > 0,
                    NSMaxRange(range) <= source.length
                else { return uncertain }
                let indices = range.location..<NSMaxRange(range)
                guard !seen.intersects(integersIn: indices) else { return uncertain }
                seen.insert(integersIn: indices)
                let bounds = line.bounds(for: page)
                // Sideways arXiv stamps and discarded crop-box matter must not interrupt the two columns.
                if bounds.height > max(30, bounds.width * 1.7) || !crop.intersects(bounds) {
                    omitted = true
                    continue
                }
                runs += fragments(on: page, source: source, range: range, crop: crop, omitted: &omitted)
            }
        }
        guard !runs.isEmpty, runs.count <= 2_000 else { return uncertain }
        if seen.count < source.length {
            for missing in (0..<source.length) where !seen.contains(missing) && !isSpace(source.character(at: missing))
            {
                omitted = true
                break
            }
        }

        let rows = physicalRows(runs)
        let readingRows = withoutMetadata(rows, source: source, crop: crop, pageIndex: pageIndex, omitted: &omitted)
        let bands = orderedColumns(rows: readingRows, crop: crop, omitted: &omitted)
        let hasWrappedHyphen = runs.contains { source.character(at: NSMaxRange($0.range) - 1) == 45 }
        let spellings = hasWrappedHyphen ? nearbySpellings(in: document, pageIndex: pageIndex, source: string) : []
        var sentences = [PDFSourceSentence]()
        readingOrder: for column in bands {
            try Task.checkCancellation()
            for group in paragraphs(in: column, source: source) {
                if let line = group.first,
                    ["references", "bibliography"].contains(content(line, source: source).lowercased())
                {
                    omitted = true
                    break readingOrder
                }
                sentences += split(
                    group, on: page, source: source, pageIndex: pageIndex, spellings: spellings, omitted: &omitted)
            }
        }
        if sentences.isEmpty { return uncertain }
        return PDFSentenceExtraction(
            sentences: sentences, notice: omitted ? "仅展示可定位的横排文字，其他内容请对照原页。" : nil)
    }

    private struct Run {
        let range: NSRange
        let bounds: CGRect
    }

    private struct Line {
        var runs: [Run]
        var bounds: CGRect
    }

    private static func isSpace(_ char: unichar) -> Bool {
        UnicodeScalar(char).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }

    /// Split even a PDFKit "line" which spans the gutter. Blank advances have no reliable geometry.
    private static func fragments(on page: PDFPage, source: NSString, range: NSRange, crop: CGRect, omitted: inout Bool)
        -> [Run]
    {
        var result = [Run]()
        var bounds = CGRect.null
        var first = 0
        var last = 0
        func finish() {
            if !bounds.isNull {
                let visible = NSRange(location: first, length: last - first + 1)
                result.append(Run(range: visible, bounds: bounds))
                bounds = .null
            }
        }
        var index = range.location
        while index < NSMaxRange(range) {
            let unit = source.character(at: index)
            if isSpace(unit) {
                if unit == 10 || unit == 13 { finish() }
                index += 1
                continue
            }
            let start = index
            while index < NSMaxRange(range), !isSpace(source.character(at: index)) { index += 1 }
            let word = NSRange(location: start, length: index - start)
            // PDFPage.characterBounds(at:) indexes drawn glyphs on some PDFs, omitting synthetic line
            // breaks. PDFSelection ranges index the extracted string, including those line breaks.
            guard let selected = page.selection(for: word), let token = selected.string,
                token == source.substring(with: word), !token.contains("\u{fffd}")
            else {
                omitted = true
                return []
            }
            let box = selected.bounds(for: page)
            guard !box.isEmpty, box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite,
                crop.contains(CGPoint(x: box.midX, y: box.midY))
            else {
                omitted = true
                return []
            }
            if !bounds.isNull,
                box.minX - bounds.maxX > max(11, box.height * 1.05)
                    || box.midX < bounds.minX - box.height
                    || abs(box.midY - bounds.midY) > max(4, bounds.height * 0.68)
            {
                finish()
            }
            if bounds.isNull { first = start }
            bounds = bounds.union(box)
            last = index - 1
        }
        finish()
        return result
    }

    private static func physicalRows(_ runs: [Run]) -> [[Line]] {
        let descending = runs.sorted {
            if $0.bounds.midY == $1.bounds.midY { return $0.bounds.minX < $1.bounds.minX }
            return $0.bounds.midY > $1.bounds.midY
        }
        var baselines = [[Run]]()
        for run in descending {
            if let first = baselines.last?.first,
                abs(first.bounds.midY - run.bounds.midY) <= max(1.3, min(first.bounds.height, run.bounds.height) * 0.48)
            {
                baselines[baselines.count - 1].append(run)
            } else {
                baselines.append([run])
            }
        }
        return baselines.map { row in
            var lines = [Line]()
            for run in row.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                if let last = lines.last, run.bounds.minX - last.bounds.maxX <= max(10, last.bounds.height * 1.05) {
                    lines[lines.count - 1].runs.append(run)
                    lines[lines.count - 1].bounds = last.bounds.union(run.bounds)
                } else {
                    lines.append(Line(runs: [run], bounds: run.bounds))
                }
            }
            return lines
        }
    }

    private static func content(_ line: Line, source: NSString) -> String {
        line.runs.map { source.substring(with: $0.range) }.joined(separator: " ")
    }

    private static func withoutMetadata(
        _ rows: [[Line]], source: NSString, crop: CGRect, pageIndex: Int, omitted: inout Bool
    ) -> [[Line]] {
        let all = rows.flatMap { $0 }
        let heights = all.map(\.bounds.height).sorted()
        let typicalHeight = heights[heights.count / 2]
        var authorBand: ClosedRange<CGFloat>?
        if pageIndex == 0,
            let title = all.first(where: {
                $0.bounds.midY > crop.midY + crop.height * 0.24
                    && $0.bounds.height > typicalHeight * 1.35 && $0.bounds.width > crop.width * 0.22
            })
        {
            let lastTitle =
                all.prefix(while: { $0.bounds.midY >= title.bounds.midY - max(22, title.bounds.height * 2.1) }).last(
                    where: {
                        $0.bounds.height > title.bounds.height * 0.8 && $0.bounds.midY <= title.bounds.midY
                    }) ?? title
            let below = all.filter { $0.bounds.maxY < lastTitle.bounds.minY - 2 }
            // An explicit abstract heading is best. Untitled abstracts start with a long prose line;
            // require mostly lowercase words to distinguish these from name and affiliation lists.
            let body =
                below.first(where: { content($0, source: source).lowercased() == "abstract" })
                ?? below.first(where: { line in
                    let words = content(line, source: source).split(whereSeparator: \.isWhitespace)
                    return words.count >= 10
                        && words.filter { $0.first?.isLowercase == true }.count * 3 > words.count * 2
                })
            if let body, lastTitle.bounds.minY > body.bounds.maxY + 2 {
                authorBand = (body.bounds.maxY + 1)...(lastTitle.bounds.minY - 1)
            }
        }
        return rows.compactMap { row in
            let readable = row.filter { line in
                let text = content(line, source: source)
                let lower = text.lowercased()
                let isPageNumber =
                    text.count < 6 && Int(text) != nil && line.bounds.midY < crop.minY + crop.height * 0.12
                let isFooter =
                    line.bounds.midY < crop.minY + crop.height * 0.2
                    && (lower.contains("corresponding author") || lower.contains("correspondence to")
                        || lower.contains("equal contribution") || lower.contains("copyright")
                        || lower.contains("this work was")
                        || lower.hasPrefix("proceedings of") || lower.contains("by the author(s)"))
                let isHeader =
                    pageIndex > 0 && line.bounds.midY > crop.maxY - crop.height * 0.1
                    && line.bounds.height < typicalHeight * 0.88
                if authorBand?.contains(line.bounds.midY) == true || isPageNumber || isFooter || isHeader
                    || (text.contains("@") && text.contains("."))
                {
                    omitted = true
                    return false
                }
                return true
            }
            return readable.isEmpty ? nil : readable
        }
    }

    /// Estimate the gutter from recurring paragraph-width lines on both sides. This also works
    /// when the PDF's two columns have different baselines or are interleaved in source order.
    private static func orderedColumns(rows: [[Line]], crop: CGRect, omitted: inout Bool) -> [[Line]] {
        let all = rows.flatMap { $0 }
        let midpoint = crop.midX
        let rightCandidates = all.filter {
            $0.bounds.width > crop.width * 0.15 && abs($0.bounds.minX - midpoint) < crop.width * 0.10
                && $0.bounds.maxX > midpoint + crop.width * 0.15
        }
        let starts = rightCandidates.map(\.bounds.minX).sorted()
        let rightStart = starts.isEmpty ? midpoint : starts[starts.count / 2]
        let leftCandidates = all.filter {
            $0.bounds.width > crop.width * 0.15 && $0.bounds.minX < midpoint - crop.width * 0.18
                && $0.bounds.maxX <= rightStart && rightStart - $0.bounds.maxX < crop.width * 0.35
        }
        let leftEnds = leftCandidates.map(\.bounds.maxX).sorted()
        let hasColumns =
            leftEnds.count >= 2 && starts.count >= 2
            && leftCandidates.contains { left in
                rightCandidates.contains { abs($0.bounds.midY - left.bounds.midY) < 30 }
            }
        guard hasColumns, let innerEdge = leftEnds.last else {
            var bands = [[Line]]()
            var body = [Line]()
            for row in rows {
                if row.count == 1 {
                    body += row
                } else {
                    omitted = true
                    if !body.isEmpty {
                        bands.append(body)
                        body.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !body.isEmpty { bands.append(body) }
            return bands
        }
        let gutter = (innerEdge + rightStart) / 2
        var ordered = [[Line]]()
        var left = [Line]()
        var right = [Line]()
        var spanning = [Line]()
        func flushColumns() {
            if !left.isEmpty {
                ordered.append(left)
                left.removeAll(keepingCapacity: true)
            }
            if !right.isEmpty {
                ordered.append(right)
                right.removeAll(keepingCapacity: true)
            }
        }
        func appendSide(_ side: [Line], to lines: inout [Line]) {
            guard let first = side.first else { return }
            // PDFKit can split one justified line into two text runs. A larger gap is likely to
            // separate chart labels or table cells; leave that region on the PDF.
            var merged = first
            for next in side.dropFirst() {
                guard next.bounds.minX - merged.bounds.maxX <= max(12, first.bounds.height * 1.55) else {
                    omitted = true
                    return
                }
                merged.runs += next.runs
                merged.bounds = merged.bounds.union(next.bounds)
            }
            lines.append(merged)
        }
        for row in rows {
            if row.contains(where: { $0.bounds.minX < gutter && $0.bounds.maxX > gutter }) {
                guard row.count == 1 else {
                    omitted = true
                    continue
                }
                flushColumns()
                spanning += row
            } else {
                if !spanning.isEmpty {
                    ordered.append(spanning)
                    spanning.removeAll(keepingCapacity: true)
                }
                appendSide(row.filter { $0.bounds.midX < gutter }, to: &left)
                appendSide(row.filter { $0.bounds.midX >= gutter }, to: &right)
            }
        }
        flushColumns()
        if !spanning.isEmpty { ordered.append(spanning) }
        return ordered
    }

    private static func isHeading(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["abstract", "introduction", "discussion", "conclusion", "references", "bibliography", "keywords"].contains(
            lower)
        {
            return true
        }
        return text.range(of: #"^\d+(?:\.\d+)*\.?\s+[A-Z]"#, options: .regularExpression) != nil
            && lower.count < 85 && !lower.hasSuffix(".")
    }

    private static func paragraphs(in column: [Line], source: NSString) -> [[Line]] {
        let pitches = zip(column, column.dropFirst()).compactMap { a, b -> CGFloat? in
            let dy = a.bounds.midY - b.bounds.midY
            return dy > 3 && dy <= 30 ? dy : nil
        }.sorted()
        let pitch = pitches.isEmpty ? 0 : pitches[pitches.count / 2]
        var groups = [[Line]]()
        for line in column {
            if let last = groups.last?.last {
                let dy = last.bounds.midY - line.bounds.midY
                let height = max(last.bounds.height, line.bounds.height)
                let indent = line.bounds.minX - last.bounds.minX
                let alignsCenters = height >= 11 && abs(line.bounds.midX - last.bounds.midX) < height
                if dy > 0, dy <= max(height * 1.95, pitch * 1.35),
                    abs(last.bounds.height - line.bounds.height) <= max(2, height * 0.32),
                    indent < max(5, height * 0.8) || alignsCenters, !isHeading(content(last, source: source)),
                    !isHeading(content(line, source: source))
                {
                    groups[groups.count - 1].append(line)
                    continue
                }
            }
            groups.append([line])
        }
        return groups
    }

    private struct Span {
        var normalized: NSRange
        let original: NSRange
        let line: Int
    }

    private static func split(
        _ lines: [Line], on page: PDFPage, source: NSString, pageIndex: Int, spellings: Set<String>, omitted: inout Bool
    )
        -> [PDFSourceSentence]
    {
        guard let firstLine = lines.first, let anchor = firstLine.runs.first?.range.location else { return [] }
        var text = ""
        var spans = [Span]()
        var length = 0
        for (lineIndex, line) in lines.enumerated() {
            for (runIndex, run) in line.runs.enumerated() {
                let chunk = source.substring(with: run.range)
                if !text.isEmpty {
                    let joinsHyphen = runIndex == 0 && (text.last == "-" || text.last == "\u{ad}")
                    let joinsGlyph = runIndex > 0 && run.bounds.minX - line.runs[runIndex - 1].bounds.maxX < 0.8
                    if joinsHyphen && shouldRemoveHyphen(in: text, next: chunk, spellings: spellings) {
                        text.removeLast()
                        length -= 1
                        spans[spans.count - 1].normalized.length -= 1
                    } else if !joinsHyphen && !joinsGlyph {
                        text += " "
                        length += 1
                    }
                }
                spans.append(
                    Span(
                        normalized: NSRange(location: length, length: run.range.length), original: run.range,
                        line: lineIndex))
                text += chunk
                length += run.range.length
            }
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(.english)
        tokenizer.string = text
        let ns = text as NSString
        var ranges = [NSRange]()
        for token in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            var range = NSRange(token, in: text)
            while range.length > 0 && isSpace(ns.character(at: range.location)) {
                range.location += 1
                range.length -= 1
            }
            while range.length > 0 && isSpace(ns.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
            guard range.length > 0 else { continue }
            if let prior = ranges.last,
                joinsAbbreviation(previous: ns.substring(with: prior), next: ns.substring(with: range))
            {
                ranges[ranges.count - 1] = NSUnionRange(prior, range)
            } else {
                ranges.append(range)
            }
        }
        let title =
            pageIndex == 0 && lines.count <= 3
            && firstLine.bounds.midY > page.bounds(for: .cropBox).midY + page.bounds(for: .cropBox).height * 0.24
            && firstLine.bounds.height >= 11 && !text.contains(". ") && !text.hasSuffix(".")
        let heading = isHeading(text) || title
        if heading { ranges = [NSRange(location: 0, length: ns.length)] }
        let paragraph = "p\(pageIndex)-b\(anchor)"
        return ranges.compactMap { sentence in
            let value = ns.substring(with: sentence)
            // Retain complete prose. A clipped sentence at a page boundary or a diagram label
            // remains visible on the PDF rather than becoming an apparently verified sentence.
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'’”)]} "))
            guard heading || (trimmed.last.map { ".!?".contains($0) } == true && value.first?.isLowercase != true),
                value.range(of: #"[A-Za-z]{36,}"#, options: .regularExpression) == nil
            else {
                omitted = true
                return nil
            }
            var bounds = [Int: CGRect]()
            var original = [NSRange]()
            for span in spans {
                let intersection = NSIntersectionRange(span.normalized, sentence)
                guard intersection.length > 0 else { continue }
                var range = NSRange(
                    location: span.original.location + intersection.location - span.normalized.location,
                    length: intersection.length)
                if NSMaxRange(intersection) == NSMaxRange(span.normalized) {
                    range.length += span.original.length - span.normalized.length
                }
                guard let box = page.selection(for: range)?.bounds(for: page), !box.isEmpty else {
                    omitted = true
                    return nil
                }
                original.append(range)
                bounds[span.line] = (bounds[span.line] ?? .null).union(box)
            }
            guard let first = original.first, !bounds.isEmpty else { return nil }
            let rects = bounds.keys.sorted().compactMap { index -> [Double]? in
                guard let box = bounds[index] else { return nil }
                return [box.minX, box.minY, box.width, box.height]
            }
            return PDFSourceSentence(
                id: "p\(pageIndex)-s\(first.location)", text: value, pageIndex: pageIndex,
                rects: rects, paragraphID: paragraph, characterRanges: original)
        }
    }

    /// Only local PDF text on the requested page and its two immediate neighbors is used for
    /// spelling evidence. No adjacent-page text becomes a reading unit or model input.
    private static func nearbySpellings(in document: PDFDocument, pageIndex: Int, source: String) -> Set<String> {
        var samples = [source]
        for neighbor in [pageIndex - 1, pageIndex + 1] where (0..<document.pageCount).contains(neighbor) {
            if let page = document.page(at: neighbor), page.numberOfCharacters <= 70_000, let text = page.string {
                samples.append(text)
            }
        }
        var words = Set<String>()
        for sample in samples {
            let tokens = sample.lowercased().split { !$0.isLetter && $0 != "-" }
            for token in tokens where token.count <= 96 && token.first != "-" && token.last != "-" {
                words.insert(String(token))
            }
        }
        return words
    }

    private static func shouldRemoveHyphen(in text: String, next: String, spellings: Set<String>) -> Bool {
        if text.last == "\u{ad}" { return true }
        let left = text.dropLast().reversed().prefix(while: { $0.isLetter }).reversed()
        let right = next.prefix(while: { $0.isLetter })
        guard !left.isEmpty, !right.isEmpty, right.first?.isLowercase == true else { return false }
        let prefix = String(left).lowercased()
        let suffix = String(right).lowercased()
        // Prefer an attested compound even when the author also uses an unhyphenated variant.
        if spellings.contains(prefix + "-" + suffix) { return false }
        return spellings.contains(prefix + suffix)
            || [
                "tion", "tions", "ation", "ations", "uation", "ments", "ment", "tive", "tives", "ity", "ities",
                "ing", "ously", "ization",
            ].contains(suffix)
    }

    private static func joinsAbbreviation(previous: String, next: String) -> Bool {
        let tail = previous.lowercased().split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        if ["fig.", "figs.", "eq.", "eqs.", "sec.", "secs.", "no.", "ref.", "refs."].contains(tail) {
            return next.first?.isNumber == true || next.hasPrefix("(") || next.hasPrefix("[")
        }
        return ["e.g.", "i.e.", "dr.", "prof.", "mr.", "mrs.", "vs."].contains(tail)
            || (previous.lowercased().hasSuffix("et al.") && next.first?.isLowercase == true)
    }
}
