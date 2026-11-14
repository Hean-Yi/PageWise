import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Publishes new fixed pages. This type intentionally has no API for editing an existing artifact.
@MainActor
public final class PageRenderer {
    public init() {}

    public func render(_ pairs: [BilingualBlock], to directory: URL, prefix: String) throws -> [PageArtifact] {
        guard !pairs.isEmpty else { return [] }
        let safePrefix = String(
            prefix.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.prefix(
                64))
        let batch = "\(safePrefix.isEmpty ? "page" : safePrefix)-\(UUID().uuidString)"
        let staging = directory.appendingPathComponent(".render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var artifacts: [PageArtifact] = []
        var draft: PageDraft?
        func finish() throws {
            guard let current = draft else { return }
            let name = "\(batch)-\(String(format: "%04d", artifacts.count + 1)).pdf"
            try current.write(to: staging.appendingPathComponent(name))
            artifacts.append(
                PageArtifact(blockIDs: current.blockIDs, sourcePage: current.sourcePage, relativePath: name))
            draft = nil
        }

        for pair in pairs {
            try Task.checkCancellation()
            guard pair.block.sourcePage >= 0, !pair.block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ReaderError.message("段落缺少原文或来源页码，未发布重排页。")
            }
            if let translation = pair.translation, translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ReaderError.message("译文为空，未发布重排页。")
            }
            if let current = draft, current.sourcePage != pair.block.sourcePage { try finish() }
            var segments = [TextSegment(text: pair.block.text, translated: false)]
            if let translation = pair.translation { segments.append(TextSegment(text: translation, translated: true)) }
            let expectedHeight =
                segments.reduce(PageDraft.paragraphSpacing) { $0 + $1.height }
                + CGFloat(segments.count - 1) * PageDraft.translationSpacing
            if let current = draft, expectedHeight <= PageDraft.contentHeight, expectedHeight > current.remainingHeight
            {
                try finish()
            }

            for (index, segment) in segments.enumerated() {
                if index > 0 { draft?.cursor -= PageDraft.translationSpacing }
                var offset = 0
                while offset < segment.attributed.length {
                    try Task.checkCancellation()
                    if let current = draft, current.remainingHeight < segment.minimumHeight { try finish() }
                    if draft == nil { draft = try PageDraft(sourcePage: pair.block.sourcePage) }
                    guard let current = draft else { throw ReaderError.message("无法创建固定页面。") }
                    let count = current.draw(segment, offset: offset, blockID: pair.block.id)
                    guard count > 0 else { throw ReaderError.message("文字无法完整分页，未发布重排页。") }
                    offset += count
                    if offset < segment.attributed.length { try finish() }
                }
            }
            draft?.cursor -= PageDraft.paragraphSpacing
        }
        try finish()
        try Task.checkCancellation()

        var published: [URL] = []
        do {
            for artifact in artifacts {
                let destination = directory.appendingPathComponent(artifact.relativePath)
                // FileManager refuses an existing destination. UUID names are also independent of caller prefixes.
                try FileManager.default.moveItem(
                    at: staging.appendingPathComponent(artifact.relativePath), to: destination)
                published.append(destination)
            }
        } catch {
            for url in published { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return artifacts
    }
}

private struct TextSegment {
    let attributed: NSAttributedString
    let framesetter: CTFramesetter
    let translated: Bool
    let minimumHeight: CGFloat
    var inset: CGFloat { translated ? 16 : 0 }
    var width: CGFloat { PageDraft.contentWidth - inset }
    var height: CGFloat {
        CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: 1_000_000), nil
        ).height
    }

    init(text: String, translated: Bool) {
        self.translated = translated
        let font = CTFontCreateWithName(
            (translated ? "PingFangSC-Regular" : "Georgia") as CFString, translated ? 12.2 : 12.8, nil)
        let color =
            translated
            ? CGColor(red: 0.19, green: 0.36, blue: 0.36, alpha: 1)
            : CGColor(red: 0.16, green: 0.18, blue: 0.20, alpha: 1)
        var spacing: CGFloat = translated ? 5.5 : 4.5
        minimumHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font) + spacing + 2)
        let paragraph = withUnsafePointer(to: &spacing) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ])
        framesetter = CTFramesetterCreateWithAttributedString(attributed)
    }
}

private final class PageDraft {
    static let contentWidth: CGFloat = 500
    static let contentHeight: CGFloat = 648
    static let translationSpacing: CGFloat = 8
    static let paragraphSpacing: CGFloat = 18
    let sourcePage: Int
    private let data: CFMutableData
    private let context: CGContext
    private(set) var blockIDs: [UUID] = []
    var cursor: CGFloat = 720
    var remainingHeight: CGFloat { cursor - 72 }

    init(sourcePage: Int) throws {
        self.sourcePage = sourcePage
        guard let data = CFDataCreateMutable(nil, 0), let consumer = CGDataConsumer(data: data) else {
            throw ReaderError.message("无法准备 PDF 页面缓冲区。")
        }
        self.data = data
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard
            let context = CGContext(
                consumer: consumer, mediaBox: &box,
                [kCGPDFContextTitle: "PaperReader fixed page"] as CFDictionary)
        else {
            throw ReaderError.message("无法创建 PDF 页面。")
        }
        self.context = context
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.993, green: 0.983, blue: 0.960, alpha: 1))
        context.fill(box)
        drawLabel("PAPERREADER", at: CGPoint(x: 56, y: 754), size: 8.5)
        drawLabel("SOURCE PAGE \(sourcePage + 1)", at: CGPoint(x: 56, y: 38), size: 8)
    }

    func draw(_ segment: TextSegment, offset: Int, blockID: UUID) -> Int {
        let top = cursor
        let bounds = CGRect(x: 56 + segment.inset, y: 72, width: segment.width, height: remainingHeight)
        let frame = CTFramesetterCreateFrame(
            segment.framesetter, CFRange(location: offset, length: 0), CGPath(rect: bounds, transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length > 0 else { return 0 }
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        if let line = lines.last, let origin = origins.last {
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, nil, &descent, nil)
            cursor = bounds.minY + origin.y - descent
        }
        if segment.translated {
            context.saveGState()
            context.setStrokeColor(CGColor(red: 0.19, green: 0.36, blue: 0.36, alpha: 0.25))
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 58, y: top - 1))
            context.addLine(to: CGPoint(x: 58, y: cursor + 1))
            context.strokePath()
            context.restoreGState()
        }
        if !blockIDs.contains(blockID) { blockIDs.append(blockID) }
        return visible.length
    }

    func write(to url: URL) throws {
        context.endPDFPage()
        context.closePDF()
        let bytes = data as Data
        guard let document = PDFDocument(data: bytes), document.pageCount == 1,
            let page = document.page(at: 0), page.numberOfCharacters > 0
        else {
            throw ReaderError.message("生成的页面校验失败，未发布。")
        }
        try bytes.write(to: url, options: .withoutOverwriting)
    }

    private func drawLabel(_ text: String, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, size, nil)
        let string = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                    red: 0.42, green: 0.45, blue: 0.44, alpha: 1),
                NSAttributedString.Key(kCTKernAttributeName as String): 0.8,
            ])
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
}
