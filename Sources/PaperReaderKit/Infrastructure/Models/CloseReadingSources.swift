import Foundation
import PDFKit
import SwiftSoup

/// Only `evidence.text` can be used as an anchor. Table rows are extra evidence read locally
/// beside the caption; they never become invented spans in the PDF or HTML.
struct CloseReadingPassage: Sendable {
    var evidence: Evidence
    let kind: String
    let table: String?

    var size: Int { evidence.text.count + (table?.count ?? 0) }
}

struct CloseReadingCorpus {
    var windows: [[CloseReadingPassage]] = []
    var coverage = ""
    static let windowLength = 14_000
    static let maxWindows = 24

    static func read(paper: Paper, root: URL, progress: @Sendable (String) async -> Void) async throws -> Self {
        // Unpublished source blocks have no stable reading anchors. For an incomplete source edition,
        // read the physical PDF from beginning to end, including pages outside the current HTML prefix.
        if let artifact = paper.htmlReading, paper.reflowJob?.finished != false, !artifact.sections.isEmpty {
            try Task.checkCancellation()
            await progress("正在读取已发布的源码段落")
            if let html = try? readHTML(paper: paper, artifact: artifact, root: root),
                !html.windows.isEmpty
            {
                return html
            }
            try Task.checkCancellation()
        }
        return try await readPDF(paper: paper, root: root, progress: progress)
    }

    private struct Collection {
        var passages: [CloseReadingPassage] = []
        var unavailable: [Int] = []
        var visuals = 0
        var tables = 0
        var shortenedTables = 0
        var partialTables = 0

        mutating func add(_ content: String, kind: String, table: String?, paper: Paper, page: Int?, block: UUID?) {
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            var rows: String?
            if let table, !table.isEmpty {
                let available = table.split(separator: "\n", omittingEmptySubsequences: false)
                var accepted: [Substring] = []
                var length = 0
                for row in available {
                    guard length + row.count + 1 <= 4_000 else { break }
                    accepted.append(row)
                    length += row.count + 1
                }
                if accepted.count < available.count { shortenedTables += 1 }
                if !accepted.isEmpty {
                    if kind == "partialTable" { partialTables += 1 }
                    rows = accepted.joined(separator: "\n")
                    tables += 1
                }
            }
            // A long paragraph is divided at word boundaries. Quotes are resolved only within
            // their original block or page; these transport slices never become reading locations.
            var rest = text[...]
            while !rest.isEmpty {
                var end = rest.index(rest.startIndex, offsetBy: 3_600, limitedBy: rest.endIndex) ?? rest.endIndex
                if end != rest.endIndex, let space = rest[..<end].lastIndex(where: \.isWhitespace),
                    space != rest.startIndex
                {
                    end = space
                }
                let fragment = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !fragment.isEmpty {
                    let source = Evidence(
                        id: "P\(passages.count + 1)", title: paper.title, text: fragment,
                        paperID: paper.id, blockID: block, sourcePage: page)
                    passages.append(.init(evidence: source, kind: kind, table: rows))
                    rows = nil
                }
                rest = rest[end...].drop(while: \.isWhitespace)
            }
        }

        func result(unit: String, total: Int, inspected: Int) -> CloseReadingCorpus {
            var batches = [[CloseReadingPassage]]()
            var batch: [CloseReadingPassage] = []
            var length = 0
            for passage in passages {
                if !batch.isEmpty && (length + passage.size > CloseReadingCorpus.windowLength || batch.count >= 70) {
                    batches.append(batch)
                    batch = []
                    length = 0
                }
                batch.append(passage)
                length += passage.size
            }
            if !batch.isEmpty { batches.append(batch) }
            let chosen = CloseReadingCorpus.indices(total: batches.count, limit: CloseReadingCorpus.maxWindows)
            var coverage = ["已检查\(inspected)/\(total)\(unit)", "已分析\(chosen.count)/\(batches.count)个文本窗口"]
            if !unavailable.isEmpty {
                let locations = unavailable.prefix(12).map { String($0 + 1) }.joined(separator: "、")
                coverage.append("\(unavailable.count)处缺少可定位正文（\(locations)\(unavailable.count > 12 ? "等" : "")）")
            }
            if inspected < total || chosen.count < batches.count { coverage.append("超出预算的部分按全文位置间隔取样") }
            if tables > 0 { coverage.append("\(tables)份可核对的表格文本") }
            if partialTables > 0 { coverage.append("其中\(partialTables)份仅核实部分列") }
            if shortenedTables > 0 { coverage.append("\(shortenedTables)份长表仅读取完整的前部行") }
            if visuals > 0 { coverage.append("\(visuals)处图像或复杂表格仅据题注、正文解读") }
            return CloseReadingCorpus(windows: chosen.map { batches[$0] }, coverage: coverage.joined(separator: " · "))
        }
    }

    private static func indices(total: Int, limit: Int) -> [Int] {
        guard total > limit else { return Array(0..<max(0, total)) }
        return (0..<limit).map { $0 * (total - 1) / (limit - 1) }
    }

    private static func readPDF(paper: Paper, root: URL, progress: @Sendable (String) async -> Void) async throws
        -> Self
    {
        let url = root.appendingPathComponent(paper.originalPath)
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount == paper.pageCount, doc.pageCount > 0 else {
            throw ReaderError.message("无法读取这篇论文的本地原文。")
        }
        let pages = indices(total: doc.pageCount, limit: 400)
        var collection = Collection()
        for pageIndex in pages {
            try Task.checkCancellation()
            await progress("正在核对原文第 \(pageIndex + 1) / \(doc.pageCount) 页")
            let before = collection.passages.count
            try autoreleasepool {
                guard let page = doc.page(at: pageIndex) else { return }
                do {
                    let text = try PDFSentenceExtractor.extractPage(url: url, pageIndex: pageIndex)
                    let regions = try PDFCaptionRegionDetector.regions(on: page)
                    var captionIDs = Set<String>()
                    for region in regions {
                        let captionSentences = text.sentences.filter { sentence in
                            sentence.characterRanges.contains {
                                NSIntersectionRange(region.captionRange, $0).length > 0
                            }
                        }
                        let paragraphs = Set(captionSentences.map(\.readingParagraphID))
                        let caption = text.sentences.filter { paragraphs.contains($0.readingParagraphID) }
                        let line = page.selectionForLine(
                            at: CGPoint(x: region.captionBounds.midX, y: region.captionBounds.midY))?.string
                        let label = (page.string as NSString?).flatMap { source in
                            NSMaxRange(region.captionRange) <= source.length
                                ? source.substring(with: region.captionRange) : nil
                        }
                        let anchor =
                            caption.isEmpty ? (line ?? label ?? "") : caption.map(\.text).joined(separator: " ")
                        captionIDs.formUnion(caption.map(\.id))
                        let table =
                            region.label.hasPrefix("表 ")
                            ? region.sourceBounds.flatMap { PDFTableExtractor.extract(on: page, in: $0) } : nil
                        var rows = table?.tabSeparatedText
                        var kind = "table"
                        if rows == nil, region.label.hasPrefix("表 "), let bounds = region.sourceBounds {
                            rows = try PDFTableEvidenceColumn.rows(on: page, in: bounds)
                            kind = "partialTable"
                        }
                        if rows == nil {
                            collection.visuals += 1
                            kind = "captionOnly"
                        }
                        collection.add(
                            anchor, kind: kind, table: rows,
                            paper: paper, page: pageIndex, block: nil)
                    }
                    var paragraph = ""
                    var previousID: String?
                    for sentence in text.sentences {
                        guard !captionIDs.contains(sentence.id),
                            !regions.contains(where: { region in
                                guard let bounds = region.sourceBounds else { return false }
                                return !sentence.rects.isEmpty
                                    && sentence.rects.allSatisfy {
                                        $0.count == 4
                                            && bounds.insetBy(dx: -1, dy: -1).contains(
                                                CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]))
                                    }
                            })
                        else { continue }
                        if sentence.readingParagraphID != previousID {
                            collection.add(
                                paragraph, kind: "prose", table: nil, paper: paper, page: pageIndex, block: nil)
                            previousID = sentence.readingParagraphID
                            paragraph = ""
                        }
                        if !paragraph.isEmpty { paragraph += " " }
                        paragraph += sentence.text
                    }
                    collection.add(paragraph, kind: "prose", table: nil, paper: paper, page: pageIndex, block: nil)
                } catch is CancellationError { throw CancellationError() } catch {
                    // The other pages can still be read; this one is accounted for below.
                }
            }
            if before == collection.passages.count { collection.unavailable.append(pageIndex) }
        }
        try Task.checkCancellation()
        return collection.result(unit: "页原文", total: doc.pageCount, inspected: pages.count)
    }

    private static func readHTML(paper: Paper, artifact: HTMLReadingArtifact, root: URL) throws -> Self {
        let url = root.appendingPathComponent(artifact.relativePath)
        HTMLReadingStore.retainOpenDocument(url)
        defer { HTMLReadingStore.releaseOpenDocument(url) }
        let doc = try SwiftSoup.parse(String(contentsOf: url, encoding: .utf8))
        guard try doc.body()?.attr("data-paper-id") == paper.id.uuidString,
            let reader = try doc.getElementById("reader")
        else {
            throw ReaderError.message("已发布源码与论文不符。")
        }
        let sections = Dictionary(
            reader.children().filter { $0.tagName() == "section" }.map { ($0.id(), $0) },
            uniquingKeysWith: { first, _ in first })
        let positions = indices(total: artifact.sections.count, limit: 8_000)
        var collection = Collection()
        for index in positions {
            try Task.checkCancellation()
            let section = artifact.sections[index]
            guard let block = section.blockIDs.first, let element = sections["block-" + section.id.uuidString] else {
                collection.unavailable.append(index)
                continue
            }
            // Remove the translation and shared objects only from this private parsing tree.
            try element.select(".translation,.pending").remove()
            // Register equations independently of the prose: selecting text cannot cross a
            // shared math object. A repeated expression in the same block has no unique locator.
            var equations: [String] = []
            var seenEquations: Set<String> = []
            var repeatedEquations: Set<String> = []
            for equation in try element.select("math,.paper-equation") {
                guard
                    !equation.parents().contains(where: {
                        ["table", "math", "svg"].contains($0.tagName()) || $0.hasClass("paper-equation")
                    }),
                    try !equation.hasClass("paper-equation") || equation.select("math").count <= 1,
                    let source = try HTMLReadingStore.publishedEquationSource(equation),
                    !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.count <= 1_490
                else { continue }
                let label = "[公式] " + source
                if !seenEquations.insert(label).inserted {
                    repeatedEquations.insert(label)
                    continue
                }
                let standalone = try equation.attr("display") == "block" || equation.hasClass("paper-equation")
                if try standalone || !equation.select("mo,mfrac,msqrt,mroot,munder,mover,munderover,mtable").isEmpty() {
                    equations.append(label)
                }
            }
            let tables = try element.select("table:not(.paper-equation)")
            let matrices = try tables.compactMap { try verifiedRows($0) }
            let hasVisualOnly = try !element.select("img,svg").isEmpty() || matrices.count < tables.count
            if hasVisualOnly { collection.visuals += 1 }
            let caption = try element.select("caption,figcaption").map { try $0.text() }.joined(separator: " ")
            try element.select("table,math,img,svg,.paper-equation").remove()
            let anchor = try element.text()
            let count = collection.passages.count
            collection.add(
                anchor.isEmpty ? ([caption] + matrices).filter { !$0.isEmpty }.joined(separator: "\n") : anchor,
                kind: matrices.isEmpty ? (hasVisualOnly ? "captionOnly" : "prose") : "table",
                table: matrices.isEmpty ? nil : matrices.joined(separator: "\n\n"), paper: paper, page: nil,
                block: block)
            for equation in equations where !repeatedEquations.contains(equation) {
                collection.add(equation, kind: "equation", table: nil, paper: paper, page: nil, block: block)
            }
            if collection.passages.count == count { collection.unavailable.append(index) }
        }
        return collection.result(unit: "个已发布源码段", total: artifact.sections.count, inspected: positions.count)
    }
    /// Expand only verified rectangular tables. Row/column spans must have an unambiguous
    /// place in the grid, since sliding a value under the wrong header changes the result.
    private static func verifiedRows(_ table: Element) throws -> String? {
        guard try table.select("table table,img,svg").isEmpty() else { return nil }
        let rows = try table.select("tr")
        guard (1...240).contains(rows.count) else { return nil }
        var grid = Array(repeating: [Int: String](), count: rows.count)
        for (row, element) in rows.enumerated() {
            var column = 0
            for cell in element.children() where cell.tagName() == "th" || cell.tagName() == "td" {
                while grid[row][column] != nil { column += 1 }
                let down = try cell.hasAttr("rowspan") ? Int(cell.attr("rowspan")) : 1
                let across = try cell.hasAttr("colspan") ? Int(cell.attr("colspan")) : 1
                guard let down, let across, (1...64).contains(across), (1...240).contains(down),
                    column + across <= 80, row + down <= rows.count
                else { return nil }
                let value = try cell.text()
                for r in row..<(row + down) {
                    for c in column..<(column + across) {
                        guard grid[r][c] == nil else { return nil }
                        // A shared data cell does not supply one independent observation per leaf.
                        if (down > 1 || across > 1) && cell.tagName() != "th" { return nil }
                        grid[r][c] = value
                    }
                }
                column += across
            }
        }
        guard let width = grid.first?.count, width > 0,
            grid.allSatisfy({ $0.count == width && $0[width - 1] != nil })
        else { return nil }
        return grid.map { row in (0..<width).map { row[$0] ?? "" }.joined(separator: "\t") }.joined(separator: "\n")
    }

}
