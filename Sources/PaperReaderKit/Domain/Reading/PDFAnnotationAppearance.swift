import Foundation

public struct PDFAnnotationAppearance: Equatable, Sendable {
    public let covered: Bool
    public let color: AnnotationColor?
    public let style: AnnotationStyle?

    public init(covered: Bool = false, color: AnnotationColor? = nil, style: AnnotationStyle? = nil) {
        self.covered = covered
        self.color = color
        self.style = style
    }
}

extension Highlight {
    var isOriginalPDFInk: Bool {
        pageIndex >= 0 && pageKey == "original-\(pageIndex)" && htmlTarget == nil && textRange == nil
            && contentVersion == nil && pdfTranslationTarget == nil
    }

    var originalPDFTextRange: Range<Int>? {
        guard isOriginalPDFInk, let start = pdfTextStart, start >= 0, !text.isEmpty,
            text.utf16.count <= Int.max - start
        else { return nil }
        return start..<(start + text.utf16.count)
    }
}

extension AnnotationRangeEditor {
    public static func pdfAppearance(
        for ranges: [Int: [NSRange]], paperID: UUID, in highlights: [Highlight]
    ) -> PDFAnnotationAppearance {
        var uncovered: [Int: IndexSet] = [:]
        for (page, parts) in ranges {
            guard page >= 0 else { return .init() }
            for range in parts {
                guard range.location >= 0, range.length > 0, range.length <= Int.max - range.location else {
                    return .init()
                }
                uncovered[page, default: []].insert(integersIn: range.location..<NSMaxRange(range))
            }
        }
        guard !uncovered.isEmpty else { return .init() }
        let selected = uncovered
        var colors = Set<AnnotationColor>()
        var styles = Set<AnnotationStyle>()
        for mark in highlights where mark.paperID == paperID {
            guard let range = mark.originalPDFTextRange, selected[mark.pageIndex]?.intersects(integersIn: range) == true
            else { continue }
            colors.insert(mark.color ?? .yellow)
            styles.insert(mark.style ?? .highlight)
            uncovered[mark.pageIndex]?.remove(integersIn: range)
        }
        guard uncovered.values.allSatisfy(\.isEmpty) else { return .init() }
        let uniform = colors.count == 1 && styles.count == 1
        return .init(covered: true, color: uniform ? colors.first : nil, style: uniform ? styles.first : nil)
    }
}
