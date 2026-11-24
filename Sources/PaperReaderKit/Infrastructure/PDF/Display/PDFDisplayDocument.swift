import CoreGraphics
import Foundation
import PDFKit

/// Gives PDFKit an independent backing document while preserving source text for selection and citations.
@MainActor
public final class PDFDisplayDocument {
    public let document: PDFDocument
    private let backingDocuments: [PDFDocument]
    private let sourcePages: [PDFPage]?

    private init(document: PDFDocument, backingDocuments: [PDFDocument] = [], sourcePages: [PDFPage]? = nil) {
        self.document = document
        self.backingDocuments = backingDocuments
        self.sourcePages = sourcePages
    }

    /// CoreGraphics can map CJK glyphs to compatibility characters while copying PDF resources.
    /// Validated character ranges recover exact source text without normalizing mathematics.
    public func text(for selection: PDFSelection, on pageIndex: Int) -> String? {
        guard (0..<(sourcePages?.count ?? document.pageCount)).contains(pageIndex),
            let displayed = document.page(at: pageIndex)
        else { return nil }
        let source = sourcePages?[pageIndex] ?? displayed
        let count = selection.numberOfTextRanges(on: displayed)
        guard count > 0 else { return nil }
        var parts: [String] = []
        for index in 0..<count {
            let range = selection.range(at: index, on: displayed)
            guard range.location != NSNotFound, range.location + range.length <= source.numberOfCharacters,
                let text = source.selection(for: range)?.string
            else { return nil }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }

    public static func load(urls: [URL], expectedPageCount: Int) throws -> PDFDisplayDocument {
        guard !urls.isEmpty else { throw ReaderError.message("没有可显示的 PDF 页面。") }
        let sources = try urls.map { url -> PDFDocument in
            guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
                throw ReaderError.message("PDF 页面缺失或无法打开，请重新打开论文。原文件未修改。")
            }
            return document
        }
        let count = sources.reduce(0) { $0 + $1.pageCount }
        guard count == expectedPageCount else {
            throw ReaderError.message("PDF 页面数量与批注定位不一致，已停止显示，避免批注错位。")
        }
        // A single original is both the display and the selection source.
        if sources.count == 1 {
            let original = sources[0]
            guard (0..<count).allSatisfy({ original.page(at: $0) != nil }) else {
                throw ReaderError.message("PDF 页面未能完整加载，已停止显示。")
            }
            return PDFDisplayDocument(document: original)
        }

        let data = NSMutableData()
        guard var firstBounds = sources[0].page(at: 0)?.bounds(for: .mediaBox) else {
            throw ReaderError.message("PDF 页面未能完整加载，已停止显示。")
        }
        guard let consumer = CGDataConsumer(data: data),
            let context = CGContext(consumer: consumer, mediaBox: &firstBounds, nil)
        else { throw ReaderError.message("PDF 页面组合失败，原始页面仍保留。") }
        var sourcePages: [PDFPage] = []
        for source in sources {
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index), let reference = page.pageRef else {
                    context.closePDF()
                    throw ReaderError.message("PDF 页面未能完整加载，已停止显示。")
                }
                sourcePages.append(page)
                var media = reference.getBoxRect(.mediaBox)
                var crop = reference.getBoxRect(.cropBox)
                let info =
                    [
                        kCGPDFContextMediaBox as String: NSData(bytes: &media, length: MemoryLayout<CGRect>.size),
                        kCGPDFContextCropBox as String: NSData(bytes: &crop, length: MemoryLayout<CGRect>.size),
                    ] as CFDictionary
                context.beginPDFPage(info)
                context.drawPDFPage(reference)
                context.endPDFPage()
            }
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), document.pageCount == count else {
            throw ReaderError.message("PDF 页面组合失败，原始页面仍保留。")
        }
        for (index, original) in sourcePages.enumerated() {
            guard let page = document.page(at: index) else {
                throw ReaderError.message("PDF 页面未能完整加载，已停止显示。")
            }
            page.rotation = original.rotation
            guard page.numberOfCharacters == original.numberOfCharacters,
                page.bounds(for: .mediaBox) == original.bounds(for: .mediaBox),
                page.bounds(for: .cropBox) == original.bounds(for: .cropBox),
                (0..<page.numberOfCharacters).allSatisfy({
                    sameBounds(page.characterBounds(at: $0), original.characterBounds(at: $0))
                })
            else {
                throw ReaderError.message("重排页的文字定位未通过校验，请切换原始 PDF 阅读。固定页面仍保留。")
            }
            for annotation in original.annotations {
                guard let copy = annotation.copy() as? PDFAnnotation else {
                    throw ReaderError.message("PDF 批注无法完整加载，已停止显示。")
                }
                page.addAnnotation(copy)
            }
        }
        return PDFDisplayDocument(document: document, backingDocuments: sources, sourcePages: sourcePages)
    }

    private static func sameBounds(_ first: CGRect, _ second: CGRect) -> Bool {
        if first == second { return true }
        return abs(first.minX - second.minX) < 0.01 && abs(first.minY - second.minY) < 0.01
            && abs(first.width - second.width) < 0.01 && abs(first.height - second.height) < 0.01
    }
}
