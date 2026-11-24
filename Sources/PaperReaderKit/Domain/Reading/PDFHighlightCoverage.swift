import CoreGraphics
import Foundation

extension Highlight {
    /// PDF marks use original page geometry, including legacy marks without character offsets.
    public func uncoveredPDFHighlight(against existing: [Highlight]) -> Highlight? {
        let covers = existing.filter { $0.paperID == paperID && $0.pageKey == pageKey }.flatMap(\.rects)
            .compactMap(PDFHighlightCoverage.rectangle)
        var result = self
        result.rects = rects.compactMap(PDFHighlightCoverage.rectangle).flatMap {
            PDFHighlightCoverage.uncovered($0, by: covers)
        }.map { [$0.minX, $0.minY, $0.width, $0.height] }
        // A clipped mark may cover only a suffix of the quote. Its whole range would overpaint prior ink.
        if result.rects != rects { result.pdfTextStart = nil }
        return result.rects.isEmpty ? nil : result
    }
}

public enum PDFHighlightCoverage {
    static func rectangle(_ values: [Double]) -> CGRect? {
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    public static func uncovered(_ rect: CGRect, by covers: [CGRect]) -> [CGRect] {
        var remaining = [rect]
        for cover in covers where cover.intersects(rect) {
            remaining = remaining.flatMap { source -> [CGRect] in
                let overlap = source.intersection(cover)
                guard !overlap.isEmpty else { return [source] }
                return [
                    CGRect(x: source.minX, y: source.minY, width: source.width, height: overlap.minY - source.minY),
                    CGRect(x: source.minX, y: overlap.maxY, width: source.width, height: source.maxY - overlap.maxY),
                    CGRect(x: source.minX, y: overlap.minY, width: overlap.minX - source.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: source.maxX - overlap.maxX, height: overlap.height),
                ].filter { !$0.isEmpty }
            }
            if remaining.isEmpty { break }
        }
        return remaining
    }
}
