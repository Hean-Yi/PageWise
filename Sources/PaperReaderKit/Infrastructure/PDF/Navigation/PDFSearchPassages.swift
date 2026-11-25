import Foundation
import PDFKit

/// Plain original-page evidence for imports which have no published text blocks yet.
enum PDFSearchPassages {
    private struct Record: Codable {
        let digest: String
        let pageCount: Int
        let body: AgentPassageIndex
    }

    static func load(_ paper: Paper, root: URL) throws -> AgentPassageIndex {
        let original = root.appendingPathComponent(paper.originalPath).standardizedFileURL
        let directory = root.appendingPathComponent("Papers/\(paper.id.uuidString)", isDirectory: true)
            .standardizedFileURL
        guard original.deletingLastPathComponent().path == directory.path,
            FileManager.default.fileExists(atPath: original.path)
        else { return AgentPassageIndex() }
        let cache = directory.appendingPathComponent("search-passages-v1.json")
        if let data = try? Data(contentsOf: cache, options: .mappedIfSafe),
            let record = try? JSONDecoder().decode(Record.self, from: data),
            record.digest == paper.digest, record.pageCount == paper.pageCount
        {
            return record.body
        }

        guard let document = PDFDocument(url: original), !document.isLocked, document.pageCount == paper.pageCount
        else { return AgentPassageIndex() }
        var body = AgentPassageIndex()
        for page in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let text = document.page(at: page)?.string else { return }
                var start = text.startIndex
                while start < text.endIndex {
                    try Task.checkCancellation()
                    var end = text.index(start, offsetBy: 1_200, limitedBy: text.endIndex) ?? text.endIndex
                    if end < text.endIndex {
                        let last = text.index(end, offsetBy: -240)
                        end = text[last..<end].lastIndex(where: \.isWhitespace) ?? end
                    }
                    let passage = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !passage.isEmpty { body.add(blockID: nil, sourcePage: page, text: passage) }
                    start = end
                }
            }
        }
        let record = Record(digest: paper.digest, pageCount: paper.pageCount, body: body)
        let data = try JSONEncoder().encode(record)
        try Task.checkCancellation()
        // A read-only or temporarily full disk still permits search for this session.
        try? data.write(to: cache, options: .atomic)
        return body
    }
}
