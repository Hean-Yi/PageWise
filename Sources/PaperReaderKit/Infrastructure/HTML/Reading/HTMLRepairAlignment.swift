import Foundation

/// Reattaches recovered objects only when unique text anchors bracket the same object sequence.
/// Empty captions, matching page numbers, or approximate titles alone never establish identity.
enum HTMLRepairAlignment {
    static func images(previous: [TextBlock], recovered: [TextBlock]) -> [UUID: TextBlock] {
        let oldText = previous.map { PDFTextCoverage.normalized($0.text) }
        let newText = recovered.map { PDFTextCoverage.normalized($0.text) }
        let oldCounts = Dictionary(grouping: oldText, by: { $0 }).mapValues(\.count)
        let newPositions = Dictionary(grouping: newText.indices, by: { newText[$0] })
        func anchor(_ index: Int) -> Int? {
            guard previous[index].preservesSourcePage != true, oldText[index].count >= 20,
                oldCounts[oldText[index]] == 1, let matches = newPositions[oldText[index]], matches.count == 1
            else { return nil }
            return matches.first
        }
        var result: [UUID: TextBlock] = [:]
        var index = 0
        while index < previous.count {
            guard previous[index].hasImageFailure == true, previous[index].preservesSourcePage == true else {
                index += 1
                continue
            }
            let start = index
            while index < previous.count, previous[index].hasImageFailure == true,
                previous[index].preservesSourcePage == true
            { index += 1 }
            guard start > 0, index < previous.count,
                let lower = anchor(start - 1), let upper = anchor(index), lower < upper
            else { continue }
            let candidates = Array(recovered[(lower + 1)..<upper])
            guard candidates.count == index - start,
                candidates.allSatisfy({
                    $0.richContent?.isFigure == true && $0.hasImageFailure != true && $0.preservesSourcePage != true
                })
            else { continue }
            for (offset, candidate) in candidates.enumerated() {
                let old = previous[start + offset]
                var updated = candidate
                updated.id = old.id
                updated.sourcePage = old.sourcePage
                result[old.id] = updated
            }
        }
        return result
    }
}
