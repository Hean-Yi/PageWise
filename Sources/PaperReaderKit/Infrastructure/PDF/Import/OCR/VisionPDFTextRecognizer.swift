import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Page-space candidates, never authoritative mathematical or structural recognition.
struct PDFOCRLine {
    let text: String
    let bounds: CGRect
    let confidence: Float
}

enum VisionPDFTextRecognizer {
    /// One image/request at a time; revision 3 is available on macOS 13 / iPadOS 16.
    static func recognize(_ page: PDFPage) throws -> [PDFOCRLine] {
        try Task.checkCancellation()
        let bounds = page.bounds(for: .cropBox)
        guard page.rotation % 360 == 0, let reference = page.pageRef,
            [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
            bounds.width > 0, bounds.height > 0
        else { throw ReaderError.message("此页方向或尺寸不适合本地 OCR，已保留原版。") }
        let scale = min(3, 2_400 / max(bounds.width, bounds.height))
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ReaderError.message("无法准备本地 OCR 图像，已保留原版。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { throw ReaderError.message("本地 OCR 图像无法读取。") }
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        // Do not let a language model silently rewrite names, symbols or numeric evidence.
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.003
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        let observations = request.results ?? []
        guard observations.count <= 600 else { throw ReaderError.message("此页 OCR 内容超过处理预算，已保留原版。") }
        let lines = observations.compactMap { observation -> PDFOCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let rect = observation.boundingBox
            return PDFOCRLine(
                text: text,
                bounds: CGRect(
                    x: bounds.minX + rect.minX * bounds.width, y: bounds.minY + rect.minY * bounds.height,
                    width: rect.width * bounds.width, height: rect.height * bounds.height),
                confidence: candidate.confidence)
        }
        guard lines.reduce(0, { $0 + $1.text.utf8.count }) <= 100_000 else {
            throw ReaderError.message("此页 OCR 文字超过处理预算，已保留原版。")
        }
        return lines
    }
}
