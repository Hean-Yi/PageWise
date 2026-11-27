import CoreGraphics
import Foundation
import PDFKit
import Vision

/// On-device offline OCR engine for scanned PDF pages without a selectable text layer.
/// Invoked explicitly on opt-in OCR requests so raster-only pages retain deterministic fallback behavior by default.
public enum PDFScannedPageOCR {
    public static func recognize(url: URL, pageIndex: Int) throws -> [PDFSourceSentence] {
        guard let document = PDFDocument(url: url), !document.isLocked,
            (0..<document.pageCount).contains(pageIndex),
            let page = document.page(at: pageIndex)
        else { throw ReaderError.message("无法读取原始 PDF 的这一页。") }
        defer { withExtendedLifetime(document) {} }
        return try recognize(on: page, pageIndex: pageIndex)
    }

    static func recognize(on page: PDFPage, pageIndex: Int) throws -> [PDFSourceSentence] {
        try Task.checkCancellation()
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 16, bounds.height > 16 else { return [] }
        let scale: CGFloat = min(2.0, max(1.0, 1600 / max(bounds.width, bounds.height)))
        let pixelWidth = max(1, Int((bounds.width * scale).rounded()))
        let pixelHeight = max(1, Int((bounds.height * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return [] }

        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()

        let observations = (request.results ?? []).compactMap {
            observation -> (text: String, rect: CGRect)? in
            guard let top = observation.topCandidates(1).first else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            let pageRect = CGRect(
                x: bounds.minX + box.minX * bounds.width,
                y: bounds.minY + box.minY * bounds.height,
                width: box.width * bounds.width,
                height: box.height * bounds.height)
            return (text, pageRect)
        }
        guard !observations.isEmpty else { return [] }
        // Sort top-to-bottom (higher Y first in PDF coordinates), then left-to-right.
        let ordered = observations.sorted { lhs, rhs in
            let dy = abs(lhs.rect.midY - rhs.rect.midY)
            if dy > max(lhs.rect.height, rhs.rect.height) * 0.45 {
                return lhs.rect.midY > rhs.rect.midY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
        return ordered.enumerated().map { index, item in
            let r = item.rect
            return PDFSourceSentence(
                id: "ocr-\(pageIndex)-\(index)",
                text: item.text,
                pageIndex: pageIndex,
                rects: [[Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]],
                paragraphID: "ocr-p-\(pageIndex)-\(index)")
        }
    }
}
