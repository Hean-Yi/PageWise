import Foundation

public struct PaperNavigationItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let sourcePage: Int
    public let depth: Int
    public let isOutline: Bool

    public init(id: String, title: String, sourcePage: Int, depth: Int, isOutline: Bool) {
        self.id = id
        self.title = title
        self.sourcePage = sourcePage
        self.depth = depth
        self.isOutline = isOutline
    }

    public static func pages(for paper: Paper) -> [PaperNavigationItem] {
        var excerpts: [Int: String] = [:]
        let paperTitle = paper.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for block in paper.blocks {
            let text = block.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty, text.compare(paperTitle, options: .caseInsensitive) != .orderedSame else { continue }
            if let existing = excerpts[block.sourcePage], existing.count >= 60 || text.count < 60 { continue }
            excerpts[block.sourcePage] = String(text.prefix(80))
        }
        return (0..<max(0, paper.pageCount)).map { page in
            let label = "第 \(page + 1) 页"
            let title = excerpts[page].map { label + " · " + $0 } ?? label
            return PaperNavigationItem(
                id: "\(paper.id.uuidString)-page-\(page)", title: title, sourcePage: page, depth: 0, isOutline: false)
        }
    }
}

/// Resolves immutable page identifiers before consulting a display index.
public enum PaperPageLocator {
    public static func resolve(pageKey: String, in paper: Paper, excluding pending: Set<UUID> = []) -> ReaderPosition? {
        if pageKey.hasPrefix("original-"), let page = Int(pageKey.dropFirst("original-".count)),
            page >= 0, page < paper.pageCount, pageKey == "original-\(page)"
        {
            return ReaderPosition(mode: "original", pageKey: pageKey, pageIndex: page)
        }
        for mode in ["reflow", "translated"] {
            let pages = artifacts(mode: mode, in: paper, excluding: pending)
            if let index = pages.firstIndex(where: { $0.id.uuidString == pageKey }) {
                return ReaderPosition(mode: mode, pageKey: pageKey, pageIndex: index)
            }
        }
        return nil
    }

    public static func sourcePage(
        for position: ReaderPosition, in paper: Paper, excluding pending: Set<UUID> = []
    ) -> Int? {
        guard let exact = resolve(pageKey: position.pageKey, in: paper, excluding: pending) else { return nil }
        if exact.mode == "original" { return exact.pageIndex }
        return artifacts(mode: exact.mode, in: paper, excluding: pending)[exact.pageIndex].sourcePage
    }

    public static func position(
        sourcePage: Int, blockID: UUID? = nil, mode: String, in paper: Paper, excluding pending: Set<UUID> = []
    ) -> ReaderPosition? {
        guard sourcePage >= 0, sourcePage < paper.pageCount else { return nil }
        if mode == "original" {
            return ReaderPosition(mode: mode, pageKey: "original-\(sourcePage)", pageIndex: sourcePage)
        }
        let pages = artifacts(mode: mode, in: paper, excluding: pending)
        let index: Int?
        if let blockID {
            index = pages.firstIndex { $0.sourcePage == sourcePage && $0.blockIDs.contains(blockID) }
        } else {
            index = pages.firstIndex { $0.sourcePage == sourcePage }
        }
        guard let index else { return nil }
        return ReaderPosition(mode: mode, pageKey: pages[index].id.uuidString, pageIndex: index)
    }

    public static func initialPosition(in paper: Paper, excluding pending: Set<UUID> = []) -> ReaderPosition? {
        for mode in ["translated", "reflow"] {
            if let first = artifacts(mode: mode, in: paper, excluding: pending).first {
                return ReaderPosition(mode: mode, pageKey: first.id.uuidString, pageIndex: 0)
            }
        }
        return position(sourcePage: 0, mode: "original", in: paper)
    }

    private static func artifacts(mode: String, in paper: Paper, excluding pending: Set<UUID>) -> [PageArtifact] {
        guard paper.canReflow else { return [] }
        let pages: [PageArtifact]
        switch mode {
        case "reflow": pages = paper.previewPages
        case "translated": pages = paper.translatedPages
        default: return []
        }
        return pages.filter { !pending.contains($0.id) }
    }
}
