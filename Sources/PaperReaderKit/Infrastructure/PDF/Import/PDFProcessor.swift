import CoreGraphics
import Foundation
import PDFKit

public struct PDFProcessingResult: Sendable {
    public let blocks: [TextBlock]
    public let warnings: [String]
    public let canReflow: Bool
}

/// A deliberately conservative text-only PDF adapter. No OCR or equation reconstruction is implied.
public enum PDFProcessor {
    public static func extract(from url: URL) throws -> PDFProcessingResult {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw ReaderError.message("无法读取 PDF。")
        }
        return try extract(from: document)
    }

    static func extract(
        from document: PDFDocument, preservingComplexPages: Bool = false,
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) throws -> PDFProcessingResult {
        var blocks: [TextBlock] = []
        var warnings: [String] = []
        if !document.allowsCopying {
            return PDFProcessingResult(blocks: [], warnings: ["此 PDF 不允许文字提取，已保留原始 PDF 阅读。"], canReflow: false)
        }
        onProgress(0, document.pageCount)
        for pageIndex in 0..<document.pageCount {
            defer { onProgress(pageIndex + 1, document.pageCount) }
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                warnings.append("第 \(pageIndex + 1) 页无法读取，已回退到原始 PDF。")
                continue
            }
            let source = page.string ?? ""
            let blockStart = blocks.count
            let warningStart = warnings.count
            defer {
                if preservingComplexPages, warnings.count > warningStart {
                    blocks.removeSubrange(blockStart..<blocks.count)
                    var block = TextBlock(sourcePage: pageIndex, text: source)
                    block.preservesSourcePage = true
                    blocks.append(block)
                    warnings.removeSubrange(warningStart..<warnings.count)
                    warnings.append("第 \(pageIndex + 1) 页保留原始版面，图表与公式未拆分重排或翻译。")
                }
            }
            let visibleCount = source.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            guard visibleCount > 0 else {
                warnings.append("第 \(pageIndex + 1) 页没有可提取文字，可能是扫描件或图像页；当前未进行 OCR，使用原始 PDF。")
                continue
            }
            if page.rotation % 360 != 0 {
                warnings.append("第 \(pageIndex + 1) 页含旋转版式，无法可靠重排，使用原始 PDF。")
            }
            if PDFGraphicsInspector.containsUnsupportedGraphics(page) {
                warnings.append("第 \(pageIndex + 1) 页含图像、图形或外部绘制对象；为避免丢失图表，使用原始 PDF。")
            }
            if page.annotations.contains(where: { $0.type != String(PDFAnnotationSubtype.link.rawValue.dropFirst()) }) {
                warnings.append("第 \(pageIndex + 1) 页已有批注或交互对象，使用原始 PDF 保留这些内容。")
            }
            if source.contains("\u{FFFD}") || source.unicodeScalars.contains(where: { $0.value == 0 }) {
                warnings.append("第 \(pageIndex + 1) 页文字编码不完整，使用原始 PDF。")
            }
            if source.rangeOfCharacter(from: CharacterSet(charactersIn: "∑∏∫√∂∇≈≠≤≥⊗⊕")) != nil {
                warnings.append("第 \(pageIndex + 1) 页含尚未验证的数学结构，使用原始 PDF 保留公式。")
            }
            // This page is already retained intact; no column/character analysis can change that decision.
            if preservingComplexPages, warnings.count > warningStart { continue }
            let extraction = positionedLines(on: page)
            guard extraction.reliable else {
                warnings.append("第 \(pageIndex + 1) 页文字坐标不完整或重叠，无法保证阅读顺序，使用原始 PDF。")
                // A fallback block remains useful for local search, but is never presented as safe reflow.
                blocks.append(
                    TextBlock(sourcePage: pageIndex, text: source.trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }
            let layout = orderedColumns(extraction.rows, pageBounds: page.bounds(for: .cropBox))
            if !layout.reliable {
                warnings.append("第 \(pageIndex + 1) 页存在复杂分栏或表格，无法可靠重排，使用原始 PDF。")
            }
            for group in layout.groups {
                blocks.append(contentsOf: paragraphs(from: group, sourcePage: pageIndex))
            }
        }
        let complete = Set(blocks.map(\.sourcePage)).count == document.pageCount
        let hasReflowableText = blocks.contains { $0.preservesSourcePage != true }
        return PDFProcessingResult(
            blocks: blocks, warnings: warnings,
            canReflow: !blocks.isEmpty
                && (warnings.isEmpty || (preservingComplexPages && complete && hasReflowableText)))
    }

    private struct TextLine {
        let text: String
        let bounds: CGRect
    }

    private static func positionedLines(on page: PDFPage) -> (rows: [[TextLine]], reliable: Bool) {
        // PDFKit inserts synthetic line breaks in page.string. Those offsets do not always match
        // characterBounds(at:), so text and geometry must come from the same line selection.
        let selections = page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []
        let pageBounds = page.bounds(for: .cropBox).insetBy(dx: -2, dy: -2)
        var reliable = !selections.isEmpty
        var lines: [TextLine] = []
        for selection in selections {
            let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, !bounds.isEmpty, bounds.minX.isFinite, bounds.minY.isFinite,
                bounds.width.isFinite, bounds.height.isFinite, pageBounds.contains(bounds)
            else {
                reliable = false
                continue
            }
            lines.append(TextLine(text: text, bounds: bounds))
        }
        // The line adapter may reorder text, but it must neither drop nor duplicate visible characters.
        func characters(in text: String) -> [UInt32: Int] {
            var counts: [UInt32: Int] = [:]
            for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                counts[scalar.value, default: 0] += 1
            }
            return counts
        }
        if characters(in: page.string ?? "") != characters(in: lines.map(\.text).joined()) { reliable = false }
        lines.sort {
            if abs($0.bounds.midY - $1.bounds.midY) > 0.5 { return $0.bounds.midY > $1.bounds.midY }
            return $0.bounds.minX < $1.bounds.minX
        }
        var rows: [[TextLine]] = []
        for line in lines {
            if let row = rows.indices.last(where: {
                guard let first = rows[$0].first else { return false }
                return abs(first.bounds.midY - line.bounds.midY)
                    < max(2, min(first.bounds.height, line.bounds.height) * 0.3)
            }) {
                rows[row].append(line)
            } else {
                rows.append([line])
            }
        }
        for index in rows.indices {
            rows[index].sort { $0.bounds.minX < $1.bounds.minX }
            for pair in zip(rows[index], rows[index].dropFirst()) {
                if pair.0.bounds.maxX > pair.1.bounds.minX + 1 { reliable = false }
            }
        }
        return (rows, reliable)
    }

    private static func orderedColumns(_ rows: [[TextLine]], pageBounds: CGRect) -> (
        groups: [[TextLine]], reliable: Bool
    ) {
        let paired = rows.filter { $0.count == 2 }
        if rows.contains(where: { $0.count > 2 }) { return ([rows.flatMap { $0 }], false) }
        let all = rows.flatMap { $0 }
        let leftCandidates = all.filter {
            $0.bounds.minX < pageBounds.midX - 24 && $0.bounds.maxX < pageBounds.midX + 6
        }
        let rightCandidates = all.filter { $0.bounds.minX > pageBounds.midX + 6 }
        let leftBounds = leftCandidates.reduce(CGRect.null) { $0.union($1.bounds) }
        let rightBounds = rightCandidates.reduce(CGRect.null) { $0.union($1.bounds) }
        let verticalOverlap = min(leftBounds.maxY, rightBounds.maxY) - max(leftBounds.minY, rightBounds.minY)
        let unalignedColumns = leftCandidates.count >= 2 && rightCandidates.count >= 2 && verticalOverlap >= 12
        guard paired.count >= 2 || unalignedColumns else {
            return ([all], paired.isEmpty)
        }
        // Repeated wide whitespace establishes a gutter, even when columns have different baselines.
        let gutterLeft = paired.count >= 2 ? paired.map { $0[0].bounds.maxX }.max()! : leftBounds.maxX
        let gutterRight = paired.count >= 2 ? paired.map { $0[1].bounds.minX }.min()! : rightBounds.minX
        guard gutterRight - gutterLeft >= 18,
            gutterLeft > pageBounds.minX + pageBounds.width * 0.2,
            gutterRight < pageBounds.maxX - pageBounds.width * 0.15
        else { return ([rows.flatMap { $0 }], false) }

        var groups: [[TextLine]] = []
        var left: [TextLine] = []
        var right: [TextLine] = []
        func flushColumns() {
            if !left.isEmpty {
                groups.append(left)
                left = []
            }
            if !right.isEmpty {
                groups.append(right)
                right = []
            }
        }
        for row in rows {
            if row.count == 1, let line = row.first,
                line.bounds.maxX > gutterLeft + 3 && line.bounds.minX < gutterRight - 3
            {
                flushColumns()
                groups.append([line])
            } else {
                for line in row {
                    if line.bounds.maxX <= gutterLeft + 3 {
                        left.append(line)
                    } else if line.bounds.minX >= gutterRight - 3 {
                        right.append(line)
                    } else {
                        return ([rows.flatMap { $0 }], false)
                    }
                }
            }
        }
        flushColumns()
        return (groups, true)
    }

    private static func paragraphs(from lines: [TextLine], sourcePage: Int) -> [TextBlock] {
        var result: [TextBlock] = []
        var paragraph = ""
        var previous: TextLine?
        for line in lines {
            if let previous {
                let gap = previous.bounds.minY - line.bounds.maxY
                let changedSize =
                    abs(previous.bounds.height - line.bounds.height) > min(previous.bounds.height, line.bounds.height)
                    * 0.25
                let indented = line.bounds.minX - previous.bounds.minX > max(12, line.bounds.height)
                if gap > max(7, line.bounds.height * 0.65) || changedSize || indented {
                    if !paragraph.isEmpty { result.append(TextBlock(sourcePage: sourcePage, text: paragraph)) }
                    paragraph = ""
                }
            }
            if !paragraph.isEmpty { paragraph += " " }
            paragraph += line.text
            previous = line
        }
        if !paragraph.isEmpty { result.append(TextBlock(sourcePage: sourcePage, text: paragraph)) }
        return result
    }

}
