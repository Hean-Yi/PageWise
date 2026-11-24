import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Test @MainActor func displayLoadsOriginalDirectlyAndRetainsSourceBytes() throws {
    let root = try displayTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("original.pdf")
    try DemoPaper.write(to: file)
    let bytes = try Data(contentsOf: file)
    let display = try PDFDisplayDocument.load(urls: [file], expectedPageCount: 2)
    let document = display.document
    #expect(document.documentURL == file)
    let page = try #require(document.page(at: 0))
    #expect(page.string?.contains("Understanding Attention") == true)
    let last = try #require(document.page(at: document.pageCount - 1))
    let selected = try #require(last.selection(for: NSRange(location: 0, length: last.numberOfCharacters)))
    #expect(display.text(for: selected, on: 1) == selected.string)
    #expect(display.text(for: selected, on: 0) == nil)
    #expect(display.text(for: selected, on: 2) == nil)
    page.addAnnotation(
        PDFAnnotation(bounds: CGRect(x: 56, y: 200, width: 80, height: 20), forType: .highlight, withProperties: nil))
    #expect(try Data(contentsOf: file) == bytes)
}

@Test @MainActor func displayCombinesPagesAndRestoresExactSourceTextAndGeometry() throws {
    let root = try displayTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("demo.pdf")
    try DemoPaper.write(to: original)
    let sourceDocument = try #require(PDFDocument(url: original))
    let urls = try (0..<sourceDocument.pageCount).map { index in
        let document = PDFDocument()
        document.insert(try #require(sourceDocument.page(at: index)?.copy() as? PDFPage), at: 0)
        let url = root.appendingPathComponent("legacy-\(index).pdf")
        #expect(document.write(to: url))
        return url
    }
    let fixture = try #require(PDFDocument(url: urls[1]))
    let annotated = try #require(fixture.page(at: 0))
    let bounds = CGRect(x: 56, y: 200, width: 80, height: 20)
    annotated.addAnnotation(PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil))
    #expect(fixture.write(to: urls[1]))
    let originalBytes = try urls.map { try Data(contentsOf: $0) }
    let sources = try urls.map { try #require(PDFDocument(url: $0)) }
    let display = try PDFDisplayDocument.load(urls: urls, expectedPageCount: 2)
    let displayed = display.document
    for index in 0..<2 {
        let source = try #require(sources[index].page(at: 0))
        let page = try #require(displayed.page(at: index))
        #expect(page.document === displayed)
        #expect(source.document === sources[index])
        #expect(page.numberOfCharacters == source.numberOfCharacters)
        #expect(page.bounds(for: .mediaBox) == source.bounds(for: .mediaBox))
        #expect(page.bounds(for: .cropBox) == source.bounds(for: .cropBox))
        #expect(page.rotation == source.rotation)
        let selected = try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
        #expect(
            display.text(for: selected, on: index)
                == source.selection(for: NSRange(location: 0, length: source.numberOfCharacters))?.string)
        for character in 0..<page.numberOfCharacters {
            let actual = page.characterBounds(at: character)
            let expected = source.characterBounds(at: character)
            if actual != expected {
                // PDF resource copying rounds fractional font advances. The visual raster must remain identical.
                #expect(abs(actual.minX - expected.minX) < 0.01)
                #expect(abs(actual.minY - expected.minY) < 0.01)
                #expect(abs(actual.width - expected.width) < 0.01)
                #expect(abs(actual.height - expected.height) < 0.01)
            }
        }
        #expect(page.annotations.map(\.bounds) == source.annotations.map(\.bounds))
        #expect(try displayRaster(page) == displayRaster(source))
    }
    let firstPage = try #require(displayed.page(at: 0))
    let firstSource = try #require(sources[0].page(at: 0))
    for text in ["Understanding", "Attention"] {
        let range = try #require(firstSource.string).range(of: text)
        let selectionRange = NSRange(try #require(range), in: try #require(firstSource.string))
        let selection = try #require(firstPage.selection(for: selectionRange))
        #expect(display.text(for: selection, on: 0) == text)
    }
    try #require(displayed.page(at: 0)).addAnnotation(
        PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil))
    for index in 0..<2 { #expect(try Data(contentsOf: urls[index]) == originalBytes[index]) }
}

@Test @MainActor func displayRejectsMissingOrMismatchedPagesInsteadOfSkipping() throws {
    let root = try displayTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("original.pdf")
    try DemoPaper.write(to: file)
    #expect(throws: (any Error).self) {
        try PDFDisplayDocument.load(urls: [file, root.appendingPathComponent("missing.pdf")], expectedPageCount: 3)
    }
    #expect(throws: (any Error).self) {
        try PDFDisplayDocument.load(urls: [file], expectedPageCount: 1)
    }
}

private func displayTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperReader-Display-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor private func displayRaster(_ page: PDFPage) throws -> Data {
    let bounds = page.bounds(for: .mediaBox)
    let width = Int(bounds.width)
    let height = Int(bounds.height)
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(bounds)
    page.draw(with: .mediaBox, to: context)
    return Data(bytes: try #require(context.data), count: width * height * 4)
}
