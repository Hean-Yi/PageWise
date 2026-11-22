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
    public static func extractPage(url: URL, pageIndex: Int, includingIllustrations: Bool = false) throws
        -> PDFSentenceExtraction
    {
        try extractPage(url: url, pageIndex: pageIndex, illustrations: includingIllustrations ? .reading : .none)
    }

    enum IllustrationUse { case none, reading, translation }

    static func extractPage(url: URL, pageIndex: Int, illustrations: IllustrationUse) throws -> PDFSentenceExtraction {
        guard let document = PDFDocument(url: url), !document.isLocked,
            (0..<document.pageCount).contains(pageIndex)
        else { throw ReaderError.message("无法读取原始 PDF 的这一页。") }
        defer { withExtendedLifetime(document) {} }
        guard let page = document.page(at: pageIndex) else {
            return PDFSentenceExtraction(sentences: [], notice: "本页无法读取，请检查原始 PDF。")
        }
        var regions: [PDFCaptionRegion]?
        func captionRegions() throws -> [PDFCaptionRegion] {
            if let regions { return regions }
            let detected = try PDFCaptionRegionDetector.regions(on: page)
            regions = detected
            return detected
        }
        let text = try extractText(on: page, document: document, pageIndex: pageIndex, captionRegions: captionRegions)
        guard illustrations != .none else { return text }
        return try PDFIllustratedPage.compose(
            text: text, on: page, pageIndex: pageIndex, includeSourceReading: illustrations == .reading,
            regions: captionRegions())
    }

    private static func extractText(
        on page: PDFPage, document: PDFDocument, pageIndex: Int, captionRegions: () throws -> [PDFCaptionRegion]
    ) throws
        -> PDFSentenceExtraction
    {
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
        var remainder = PDFSourceRemainder()
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
                if bounds.isEmpty || bounds.isInfinite || !bounds.minX.isFinite || !bounds.minY.isFinite {
                    remainder.add(range.location..<NSMaxRange(range), on: page, source: source, within: crop)
                    continue
                }
                guard crop.intersects(bounds) else { continue }
                if bounds.height > max(30, bounds.width * 1.7) {
                    // Ignore the rotated preprint stamp. Other rotated labels can belong to a figure or equation.
                    let margin = min(bounds.midX - crop.minX, crop.maxX - bounds.midX)
                    let stamp =
                        margin < crop.width * 0.09
                        && source.substring(with: range).localizedCaseInsensitiveContains("arxiv")
                    if !stamp { remainder.add(bounds, within: crop) }
                    continue
                }
                var damaged = false
                runs += fragments(on: page, source: source, range: range, crop: crop, omitted: &damaged)
                if damaged { remainder.add(bounds, within: crop) }
            }
        }
        guard !runs.isEmpty, runs.count <= 2_000 else { return uncertain }
        if seen.count < source.length {
            var missing = IndexSet(integersIn: 0..<source.length)
            missing.subtract(seen)
            for range in missing.rangeView { remainder.add(range, on: page, source: source, within: crop) }
        }

        // A wrap-around float is local to a few rows. Remove its own source ranges before estimating
        // page-wide columns, so the sentence beside it can continue onto a full-width line below.
        let possibleFloat = runs.contains { run in
            let text = source.substring(with: run.range)
            let leading = text.prefix { $0.isLetter }.lowercased()
            guard leading == "table" || leading == "tab" else { return false }
            let b = run.bounds
            return runs.contains {
                let peer = $0.bounds
                return peer.width > crop.width * 0.12 && abs(peer.midY - b.midY) < b.height * 6
                    && abs(peer.midY - b.midY) > b.height && (peer.maxX < b.minX || peer.minX > b.maxX)
            }
        }
        let wrapped = possibleFloat ? wrappedTables(in: runs, regions: try captionRegions(), crop: crop) : []
        var floatRanges = Set<Int>()
        for table in wrapped {
            for run in table.cells {
                floatRanges.insert(run.range.location)
                remainder.add(run.bounds, within: crop)
            }
            for line in table.caption {
                for run in line.runs { floatRanges.insert(run.range.location) }
            }
        }
        let rows = physicalRows(runs.filter { !floatRanges.contains($0.range.location) })
        let readingRows = withoutMetadata(rows, source: source, crop: crop, pageIndex: pageIndex, remainder: &remainder)
        let bands = orderedColumns(rows: readingRows, crop: crop, omitted: &omitted)
        let hasWrappedHyphen = runs.contains { source.character(at: NSMaxRange($0.range) - 1) == 45 }
        let spellings = hasWrappedHyphen ? nearbySpellings(in: document, pageIndex: pageIndex, source: string) : []
        var sentences = [PDFSourceSentence]()
        var unpairedRegions = Set<String>()
        var isFirstGroup = true
        readingOrder: for column in bands {
            try Task.checkCancellation()
            for group in paragraphs(in: column, source: source) {
                if let line = group.first,
                    ["references", "bibliography"].contains(content(line, source: source).lowercased())
                {
                    if isFirstGroup {
                        return PDFSentenceExtraction(sentences: [], notice: "本页为参考文献，保留原文。")
                    }
                    omitted = true
                    break readingOrder
                }
                isFirstGroup = false
                sentences += split(
                    group, on: page, source: source, pageIndex: pageIndex, spellings: spellings, omitted: &omitted,
                    unpairedRegions: &unpairedRegions)
            }
        }
        for table in wrapped {
            let caption = split(
                table.caption, on: page, source: source, pageIndex: pageIndex, spellings: spellings,
                omitted: &omitted, unpairedRegions: &unpairedRegions)
            guard let anchor = table.caption.first else { continue }
            var insertion =
                sentences.firstIndex { sentence in
                    guard let rect = sentence.rects.first else { return false }
                    return rect[1] + rect[3] / 2 < anchor.bounds.midY
                } ?? sentences.endIndex
            if insertion > 0 {
                let preceding = sentences[insertion - 1].readingParagraphID
                while insertion < sentences.count && sentences[insertion].readingParagraphID == preceding {
                    insertion += 1
                }
            }
            sentences.insert(contentsOf: caption, at: insertion)
        }
        if sentences.isEmpty { return uncertain }
        // A rejected fragment may sit on the same baseline as a verified sentence. Subtract the
        // exact source ranges before asking PDFKit for the fragment bounds, preserving both.
        if omitted || !unpairedRegions.isEmpty {
            var covered = IndexSet()
            for sentence in sentences {
                for range in sentence.characterRanges {
                    covered.insert(integersIn: range.location..<NSMaxRange(range))
                }
            }
            for row in readingRows + wrapped.map(\.caption) {
                for run in row.flatMap(\.runs) {
                    let range = run.range.location..<NSMaxRange(run.range)
                    if covered.contains(integersIn: range) { continue }
                    if !covered.intersects(integersIn: range) {
                        remainder.add(run.bounds, within: crop)
                    } else {
                        var missing = IndexSet(integersIn: range)
                        missing.subtract(covered)
                        for part in missing.rangeView { remainder.add(part, on: page, source: source, within: crop) }
                    }
                }
            }
        }
        let notice: String?
        if !unpairedRegions.isEmpty {
            let locations = unpairedRegions.sorted().joined(separator: "、")
            notice = "\(locations)有文字无法可靠配对，请在原页核对。"
        } else {
            notice = remainder.hasUnlocatedText || !remainder.bounds.isEmpty ? "本页有部分内容需在原页核对。" : nil
        }
        return PDFSentenceExtraction(
            sentences: sentences, notice: notice, unpairedBounds: remainder.bounds,
            hasUnlocatedText: remainder.hasUnlocatedText)
    }

    private struct Run {
        let range: NSRange
        let bounds: CGRect
    }

    private struct Line {
        var runs: [Run]
        var bounds: CGRect
    }

    private struct WrappedTable {
        let cells: [Run]
        let caption: [Line]
    }

    private static func wrappedTables(in runs: [Run], regions: [PDFCaptionRegion], crop: CGRect) -> [WrappedTable] {
        regions.compactMap { region in
            guard region.label.hasPrefix("表 "), let table = region.sourceBounds else { return nil }
            let anchor = region.captionBounds
            let height = anchor.height
            let frame = anchor.union(table)
            let right = frame.midX > crop.midX
            // Require substantive, tightly adjacent prose beside the caption as well as a nearby
            // line crossing that gutter. A regular two-column page keeps its usual reading order.
            let peers = runs.filter {
                let box = $0.bounds
                let gap = right ? frame.minX - box.maxX : box.minX - frame.maxX
                return box.width > crop.width * 0.12 && (0...height * 4).contains(gap)
                    && abs(box.midY - anchor.midY) < height * 6
            }
            guard peers.count >= 3, let top = peers.map(\.bounds.midY).max(),
                let bottom = peers.map(\.bounds.midY).min(), top - bottom > height * 1.8,
                runs.contains(where: {
                    let b = $0.bounds
                    let edge = right ? frame.minX : frame.maxX
                    return abs(b.midY - anchor.midY) < frame.height + height * 10
                        && b.minX < edge - crop.width * 0.12 && b.maxX > edge + crop.width * 0.12
                })
            else { return nil }

            let inTable = table.insetBy(dx: -1, dy: -1)
            let cells = runs.filter { inTable.contains($0.bounds) }
            let lane = frame.insetBy(dx: -3, dy: 0)
            let local = runs.filter {
                let b = $0.bounds
                return b.minX >= lane.minX && b.maxX <= lane.maxX && !inTable.contains(b)
                    && b.midY <= anchor.midY + height * 0.5
            }
            var caption = [Line]()
            for row in physicalRows(local) {
                guard let first = row.first else { continue }
                let line = Line(runs: row.flatMap(\.runs), bounds: row.reduce(CGRect.null) { $0.union($1.bounds) })
                if caption.isEmpty {
                    guard line.runs.contains(where: { NSIntersectionRange($0.range, region.captionRange).length > 0 })
                    else { continue }
                } else if let previous = caption.last {
                    let pitch = previous.bounds.midY - line.bounds.midY
                    let nextCaption = regions.contains { other in
                        other.captionRange != region.captionRange
                            && line.runs.contains { NSIntersectionRange($0.range, other.captionRange).length > 0 }
                    }
                    guard !nextCaption, (height * 0.5...height * 1.65).contains(pitch),
                        abs(first.bounds.minX - anchor.minX) < height * 0.8,
                        (height * 0.70...height * 1.4).contains(line.bounds.height)
                    else { break }
                }
                caption.append(line)
            }
            guard !caption.isEmpty else { return nil }
            return WrappedTable(cells: cells, caption: caption)
        }
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
        _ rows: [[Line]], source: NSString, crop: CGRect, pageIndex: Int, remainder: inout PDFSourceRemainder
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
                    row.count == 1 && text.count < 6 && Int(text) != nil
                    && line.bounds.midY < crop.minY + crop.height * 0.12
                let isFooter =
                    line.bounds.midY < crop.minY + crop.height * 0.2
                    && (lower.contains("corresponding author") || lower.contains("correspondence to")
                        || lower.contains("equal contribution") || lower.contains("copyright")
                        || lower.contains("this work was")
                        || lower.hasPrefix("proceedings of") || lower.contains("by the author(s)"))
                let isHeader =
                    pageIndex > 0 && line.bounds.midY > crop.maxY - crop.height * 0.1
                    && line.bounds.height < typicalHeight * 0.88
                if isPageNumber { return false }
                if authorBand?.contains(line.bounds.midY) == true || isFooter || isHeader
                    || (text.contains("@") && text.contains("."))
                {
                    remainder.add(line.bounds, within: crop)
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

    private static func danglingSection(_ text: String) -> Substring? {
        text.wholeMatch(of: /([0-9]+(?:\.[0-9]+)*)\.?\s+[A-Z].*\s(?:in|of|for|on|with|and|to)/)?.1
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
        var joined = [[Line]]()
        for group in groups {
            if group.count == 1, let next = group.first, let last = joined.last, last.count == 1,
                let first = last.first,
                joinsSectionHeading(first, continuation: next, source: source)
            {
                joined[joined.count - 1].append(next)
            } else {
                joined.append(group)
            }
        }
        return joined
    }

    private static func joinsSectionHeading(_ first: Line, continuation: Line, source: NSString) -> Bool {
        let prefix = content(first, source: source)
        guard danglingSection(prefix) != nil else { return false }
        let suffix = content(continuation, source: source)
        let height = first.bounds.height
        let indent = continuation.bounds.minX - first.bounds.minX
        let gap = first.bounds.midY - continuation.bounds.midY
        return suffix.first?.isUppercase == true && isHeading(prefix + " " + suffix)
            && abs(height - continuation.bounds.height) <= height * 0.08
            && (height * 0.5...height * 2).contains(indent) && (height * 0.8...height * 1.6).contains(gap)
    }

    private struct Span {
        var normalized: NSRange
        let original: NSRange
        let line: Int
    }

    /// Refine the reading layout while keeping the extraction groups used by existing translation caches.
    private static func readingParagraphAnchors(in lines: [Line], source: NSString, firstAnchor: Int) -> [Int] {
        let adjacent = zip(lines, lines.dropFirst())
        let gaps = adjacent.map { $0.bounds.midY - $1.bounds.midY }.sorted()
        let pitch = gaps.count >= 3 ? gaps[(gaps.count - 1) / 2] : CGFloat.infinity
        var current = firstAnchor
        var anchors = [current]
        for (previous, line) in adjacent {
            let gap = previous.bounds.midY - line.bounds.midY
            let text = content(line, source: source)
            let afterSentence =
                gap > pitch * 1.35 && text.first?.isUppercase == true
                && content(previous, source: source).trimmingCharacters(in: CharacterSet(charactersIn: "\"'’”)]} "))
                    .last.map { ".!?".contains($0) } == true
            // A small, inset table cell above a larger caption can share the same baseline pitch as prose.
            let afterTable =
                previous.bounds.minX - line.bounds.minX > line.bounds.height * 2
                && previous.bounds.height < line.bounds.height * 0.85
                && PDFCaptionRegionDetector.captionLabel(in: text) != nil
            if afterSentence || afterTable, let anchor = line.runs.first?.range.location { current = anchor }
            anchors.append(current)
        }
        return anchors
    }

    private static func split(
        _ lines: [Line], on page: PDFPage, source: NSString, pageIndex: Int, spellings: Set<String>,
        omitted: inout Bool,
        unpairedRegions: inout Set<String>
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
        if heading, let section = danglingSection(text) {
            unpairedRegions.insert("第 \(section) 节标题处")
            return []
        }
        if heading { ranges = [NSRange(location: 0, length: ns.length)] }
        let paragraph = "p\(pageIndex)-b\(anchor)"
        let readingAnchors = readingParagraphAnchors(in: lines, source: source, firstAnchor: anchor)
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
            var readingAnchor: Int?
            for span in spans {
                let intersection = NSIntersectionRange(span.normalized, sentence)
                guard intersection.length > 0 else { continue }
                if let readingAnchor, readingAnchor != readingAnchors[span.line] {
                    let label = PDFCaptionRegionDetector.captionLabel(in: content(lines[span.line], source: source))
                    unpairedRegions.insert(label.map { "\($0) 附近" } ?? "段落交界处")
                    return nil
                }
                readingAnchor = readingAnchors[span.line]
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
            guard let first = original.first, let readingAnchor, !bounds.isEmpty else { return nil }
            let rects = bounds.keys.sorted().compactMap { index -> [Double]? in
                guard let box = bounds[index] else { return nil }
                return [box.minX, box.minY, box.width, box.height]
            }
            return PDFSourceSentence(
                id: "p\(pageIndex)-s\(first.location)", text: value, pageIndex: pageIndex,
                rects: rects, paragraphID: paragraph, characterRanges: original,
                readingParagraphID: "p\(pageIndex)-b\(readingAnchor)")
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
