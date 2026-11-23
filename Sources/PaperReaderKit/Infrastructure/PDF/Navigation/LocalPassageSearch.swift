import Foundation
import PDFKit

public struct LocalPassageChoice: Identifiable, Sendable {
    public let id: String
    public let evidence: Evidence
    public let quote: String
    public let location: String
    public fileprivate(set) var pdfRanges: [NSRange] = []
}

/// PDFKit objects stay within one background operation. Extract reading-order sentences only on matching pages.
public enum LocalPassageSearch {
    public static func choices(paper: Paper, root: URL, query: String, pageIndex: Int?) async throws
        -> [LocalPassageChoice]
    {
        let limit = 12
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = paper.htmlReading
        var choices: [LocalPassageChoice] = []
        if pageIndex == nil, let html {
            let blocks = Dictionary(paper.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (index, section) in html.sections.enumerated() {
                try Task.checkCancellation()
                for blockID in section.blockIDs {
                    guard let block = blocks[blockID], let excerpt = excerpt(of: block.text, matching: term) else {
                        continue
                    }
                    let id = "\(paper.id)/\(blockID)"
                    let evidence = Evidence(
                        id: id, title: paper.title, text: excerpt, paperID: paper.id,
                        blockID: blockID, sourcePage: block.sourcePage >= 0 ? block.sourcePage : nil)
                    choices.append(.init(id: id, evidence: evidence, quote: excerpt, location: "源码第 \(index + 1) 段"))
                    if choices.count == limit { return choices }
                }
            }
            if !choices.isEmpty || term.isEmpty { return choices }
        }
        if let pageIndex, !(0..<paper.pageCount).contains(pageIndex) { throw ReaderError.message("原文页码超出了这篇论文的范围。") }
        let url = root.appendingPathComponent(paper.originalPath)
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw ReaderError.message("无法读取这篇本地 PDF。")
        }
        let pages: Range<Int>
        if let pageIndex {
            pages = pageIndex..<(pageIndex + 1)
        } else {
            pages = 0..<(term.isEmpty ? min(1, document.pageCount) : document.pageCount)
        }
        for page in pages {
            try Task.checkCancellation()
            if !term.isEmpty && pageIndex == nil {
                guard let raw = document.page(at: page)?.string,
                    matches(raw, term: term) || matches(compact(raw), term: compact(term))
                else { continue }
            }
            let extracted = try PDFSentenceExtractor.extractPage(url: url, pageIndex: page)
            for sentence in extracted.sentences {
                guard let quote = excerpt(of: sentence.text, matching: term) else { continue }
                let id = "\(paper.id)/\(sentence.id)"
                let evidence = Evidence(id: id, title: paper.title, text: quote, paperID: paper.id, sourcePage: page)
                choices.append(
                    .init(
                        id: id, evidence: evidence, quote: quote, location: "原文第 \(page + 1) 页",
                        pdfRanges: sentence.characterRanges))
                if choices.count == limit { return choices }
            }
        }
        return choices
    }

    public static func related(query: String, papers: [Paper], root: URL, limit: Int) async throws -> [Evidence] {
        let common: Set<String> = [
            "the", "and", "for", "with", "from", "that", "into", "are", "using", "this", "which", "paper", "their",
            "what", "can", "about", "study", "based",
        ]
        let terms = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).filter {
            $0.count >= 2 && !common.contains($0)
        }
        let limit = min(max(0, limit), 12)
        guard limit > 0, !terms.isEmpty else { return [] }
        func hits(_ text: String) -> [String] {
            terms.filter { matches(text, term: $0) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        }
        // Limit the optional cross-paper lookup without shortening the main paper's close read.
        let ranked = papers.map { ($0, hits($0.title).count) }.sorted {
            $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id.uuidString < $1.0.id.uuidString
        }
        var results: [(score: Int, evidence: Evidence)] = []
        for (paper, titleScore) in ranked.prefix(12) {
            try Task.checkCancellation()
            var best: (score: Int, evidence: Evidence)?
            func consider(text: String, page: Int?, block: UUID?) {
                let matched = hits(text)
                guard let term = matched.first, let quote = excerpt(of: text, matching: term) else { return }
                let score = matched.count * 3 + titleScore
                guard score > (best?.score ?? 0) else { return }
                let evidence = Evidence(
                    id: "\(paper.id)/\(block?.uuidString ?? String(page ?? 0))",
                    title: paper.title, text: quote, paperID: paper.id, blockID: block, sourcePage: page)
                best = (score, evidence)
            }
            let published = Set(paper.htmlReading?.sections.flatMap(\.blockIDs) ?? [])
            for block in paper.blocks
            where published.contains(block.id) || (0..<paper.pageCount).contains(block.sourcePage) {
                consider(text: block.text, page: block.sourcePage >= 0 ? block.sourcePage : nil, block: block.id)
            }
            if best == nil {
                let url = root.appendingPathComponent(paper.originalPath)
                if let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 {
                    // Survey spaced pages, then inspect the most relevant page in reading order.
                    let samples = min(12, pdf.pageCount)
                    var pages: [(index: Int, score: Int)] = []
                    for sample in 0..<samples {
                        try Task.checkCancellation()
                        let index = samples == 1 ? 0 : sample * (pdf.pageCount - 1) / (samples - 1)
                        guard let text = pdf.page(at: index)?.string else { continue }
                        let score = hits(text).count
                        if score > 0 { pages.append((index, score)) }
                    }
                    let chosen = pages.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
                        .prefix(2)
                    for page in chosen {
                        try Task.checkCancellation()
                        guard let extraction = try? PDFSentenceExtractor.extractPage(url: url, pageIndex: page.index)
                        else { continue }
                        for sentence in extraction.sentences where sentence.text.count >= 30 {
                            consider(text: sentence.text, page: page.index, block: nil)
                        }
                    }
                }
            }
            if let best { results.append(best) }
        }
        return results.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.evidence.id < $1.evidence.id
        }.prefix(limit).map(\.evidence)
    }

    private static func matches(_ text: String, term: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func compact(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    private static func excerpt(of body: String, matching term: String) -> String? {
        let text = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let query = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let match: Range<String.Index>
        if query.isEmpty {
            match = text.startIndex..<text.startIndex
        } else if let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            match = found
        } else {
            return nil
        }
        if text.count <= 460 { return text }
        let start = text.index(match.lowerBound, offsetBy: -120, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 460, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
