import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Suite struct PDFTests {
    @Test func importsAndRetainsSingleColumnOriginal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.pdf")
        try makeFixture(at: input, title: "Coordinate-aware reading") { context in
            draw("First paragraph explains how attention combines evidence.", x: 54, y: 720, in: context)
            draw("Its second line remains part of the same paragraph.", x: 54, y: 702, in: context)
            draw("Second paragraph introduces a separate result.", x: 54, y: 662, in: context)
        }
        let root = directory.appendingPathComponent("library")
        let paper = try await PDFImporter(root: root).importPDF(at: input)
        #expect(paper.title == "Coordinate-aware reading")
        #expect(paper.canReflow)
        #expect(paper.pageCount == 1)
        #expect(paper.blocks.count == 2)
        #expect(paper.blocks.allSatisfy { $0.sourcePage == 0 })
        #expect(paper.blocks.first?.text.contains("Its second line") == true)
        #expect(paper.blocks.last?.text.hasPrefix("Second paragraph") == true)
        let bytes = try Data(contentsOf: input)
        #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == bytes)
        #expect(paper.digest == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(paper.originalPath == "Papers/\(paper.id.uuidString)/original.pdf")
        let duplicate = try await PDFImporter(root: root).importPDF(at: input)
        #expect(duplicate.digest == paper.digest)
    }

    @Test func ordersSimpleTwoColumnsByCoordinates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("two-columns.pdf")
        try makeFixture(at: input) { context in
            // Deliberately put right-column drawing commands before left-column commands.
            draw("RIGHT_START is read after the left.", x: 326, y: 704, in: context)
            draw("The right column continues here.", x: 326, y: 686, in: context)
            draw("RIGHT_END concludes the discussion.", x: 326, y: 668, in: context)
            draw("LEFT_START begins the argument.", x: 54, y: 704, in: context)
            draw("The left column continues here.", x: 54, y: 686, in: context)
            draw("LEFT_END completes the evidence.", x: 54, y: 668, in: context)
            draw("A two-column study", x: 54, y: 750, size: 18, in: context)
        }
        let paper = try await PDFImporter(root: directory.appendingPathComponent("library")).importPDF(at: input)
        #expect(paper.canReflow)
        let text = paper.blocks.map(\.text).joined(separator: "\n")
        let startLeft = try #require(text.range(of: "LEFT_START"))
        let endLeft = try #require(text.range(of: "LEFT_END"))
        let startRight = try #require(text.range(of: "RIGHT_START"))
        let endRight = try #require(text.range(of: "RIGHT_END"))
        #expect(startLeft.lowerBound < endLeft.lowerBound)
        #expect(endLeft.lowerBound < startRight.lowerBound)
        #expect(startRight.lowerBound < endRight.lowerBound)
    }

    @Test func invalidPDFIsRejectedWithoutCreatingOriginal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("invalid.pdf")
        try Data("This is an HTML error response, not a PDF.".utf8).write(to: input)
        let root = directory.appendingPathComponent("library")
        do {
            _ = try await PDFImporter(root: root).importPDF(at: input)
            Issue.record("Invalid PDF was accepted")
        } catch {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Papers").path))
        }
    }

    @Test func scannedAndGraphicPagesHaveExplicitFallback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("scan.pdf")
        try makeFixture(at: input) { context in
            let bitmap = CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bitmap.setFillColor(CGColor(gray: 0.7, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.draw(bitmap.makeImage()!, in: CGRect(x: 54, y: 54, width: 504, height: 684))
        }
        let importer = PDFImporter(root: directory.appendingPathComponent("library"))
        let scanned = try await importer.importPDF(at: input)
        #expect(!scanned.canReflow)
        #expect(!scanned.warnings.isEmpty)
        #expect(scanned.blocks.isEmpty)

        let graphic = directory.appendingPathComponent("figure.pdf")
        try makeFixture(at: graphic) { context in
            draw("The figure below is essential to interpreting the result.", x: 54, y: 720, in: context)
            context.move(to: CGPoint(x: 54, y: 600))
            context.addLine(to: CGPoint(x: 240, y: 650))
            context.strokePath()
        }
        let illustrated = try await importer.importPDF(at: graphic)
        #expect(!illustrated.canReflow)
        #expect(illustrated.warnings.contains { $0.contains("图") })
        #expect(!illustrated.blocks.isEmpty)
    }

    @Test func acceptsWhiteBackgroundAndDecorativeHeaderRule() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("decorations.pdf")
        try makeFixture(at: input) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(0.6)
            context.move(to: CGPoint(x: 54, y: 750))
            context.addLine(to: CGPoint(x: 558, y: 750))
            context.strokePath()
            draw("A decorative header rule does not change the reading order.", x: 54, y: 720, in: context)
            draw("The complete paragraph remains available for reflow.", x: 54, y: 702, in: context)
        }
        let paper = try await PDFImporter(root: directory.appendingPathComponent("library")).importPDF(at: input)
        #expect(paper.canReflow)
        #expect(paper.blocks.map(\.text).joined().contains("complete paragraph"))
    }

    @Test func originalAnnotationsAreNotSilentlyDiscarded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("annotated.pdf")
        try makeFixture(at: input) { context in
            draw("The original annotation carries information that must be preserved.", x: 54, y: 720, in: context)
        }
        let document = try #require(PDFDocument(url: input))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 54, y: 600, width: 120, height: 60), forType: .square, withProperties: nil)
        try #require(document.page(at: 0)).addAnnotation(annotation)
        #expect(document.write(to: input))
        let paper = try await PDFImporter(root: directory.appendingPathComponent("library")).importPDF(at: input)
        #expect(!paper.canReflow)
        #expect(paper.warnings.contains { $0.contains("批注") })
    }

    @Test func ordersTwoColumnsWithDifferentBaselines() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("offset-columns.pdf")
        try makeFixture(at: input) { context in
            draw("LEFT_START is the first column.", x: 54, y: 720, in: context)
            draw("LEFT_END finishes this column.", x: 54, y: 702, in: context)
            draw("RIGHT_START begins the next column.", x: 326, y: 711, in: context)
            draw("RIGHT_END follows that evidence.", x: 326, y: 693, in: context)
        }
        let paper = try await PDFImporter(root: directory.appendingPathComponent("library")).importPDF(at: input)
        #expect(paper.canReflow)
        let text = paper.blocks.map(\.text).joined(separator: " ")
        #expect(
            try #require(text.range(of: "LEFT_END")).lowerBound < #require(text.range(of: "RIGHT_START")).lowerBound)
    }

    @Test func complexColumnsAndEquationRulesHaveExplicitFallback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("three-columns.pdf")
        try makeFixture(at: input) { context in
            for x: CGFloat in [54, 230, 406] {
                draw("Complex column begins.", x: x, y: 720, in: context)
                draw("Column continues here.", x: x, y: 702, in: context)
            }
        }
        let importer = PDFImporter(root: directory.appendingPathComponent("library"))
        let columns = try await importer.importPDF(at: input)
        #expect(!columns.canReflow)
        #expect(!columns.warnings.isEmpty)
        let equation = directory.appendingPathComponent("equation.pdf")
        try makeFixture(at: equation) { context in
            draw("This equation uses a fraction whose geometry must be retained.", x: 54, y: 720, in: context)
            context.setLineWidth(0.6)
            context.move(to: CGPoint(x: 160, y: 400))
            context.addLine(to: CGPoint(x: 300, y: 400))
            context.strokePath()
        }
        let fraction = try await importer.importPDF(at: equation)
        #expect(!fraction.canReflow)
        #expect(fraction.warnings.contains { $0.contains("图") })
    }

    @MainActor @Test func paginatesSelectableBilingualTextAndNeverRewritesPublishedPages() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = (0..<180).map { "Sentence\($0) attention links a query to relevant evidence." }.joined(
            separator: " ")
        let translation = String(repeating: "注意力根据查询选择相关证据，并保留每个段落的来源。", count: 130)
        let block = TextBlock(sourcePage: 3, text: original)
        let renderer = PageRenderer()
        let first = try renderer.render(
            [BilingualBlock(block: block, translation: translation)], to: directory, prefix: "same-prefix")
        #expect(first.count > 2)
        #expect(first.allSatisfy { $0.blockIDs == [block.id] && $0.sourcePage == 3 })
        var selected = ""
        var bodyText = ""
        var oldBytes: [String: Data] = [:]
        for artifact in first {
            #expect(!artifact.relativePath.contains("/"))
            let url = directory.appendingPathComponent(artifact.relativePath)
            oldBytes[artifact.relativePath] = try Data(contentsOf: url)
            let document = try #require(PDFDocument(url: url))
            #expect(document.pageCount == 1)
            let page = try #require(document.page(at: 0))
            #expect(page.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 612, height: 792))
            selected += page.string ?? ""
            #expect(
                page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))?.string?.isEmpty == false)
            for line in page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? [] {
                let bounds = line.bounds(for: page)
                let content = (line.string ?? "").filter { !$0.isWhitespace }
                let isLabel = ["ORIGINAL", "ORIGINAL/CONTINUED", "中文译文", "中文译文/CONTINUED"].contains(content)
                if !isLabel && bounds.minY >= 72 && bounds.maxY <= 720 {
                    bodyText += line.string ?? ""
                }
            }
        }
        #expect(selected.contains("Sentence0"))
        #expect(selected.contains("Sentence179"))
        #expect(selected.contains("注意力"))
        let actualText = bodyText.filter { !$0.isWhitespace }
        let expectedText = (original + translation).filter { !$0.isWhitespace }
        #expect(actualText.utf16.count == expectedText.utf16.count)
        #expect(SHA256.hash(data: Data(actualText.utf8)) == SHA256.hash(data: Data(expectedText.utf8)))
        let next = TextBlock(
            sourcePage: 4, text: "A later completed paragraph must append without modifying earlier pages.")
        let appended = try renderer.render(
            [BilingualBlock(block: next, translation: "后续译文追加为新的固定页。")], to: directory, prefix: "same-prefix")
        #expect(Set(first.map(\.relativePath)).isDisjoint(with: Set(appended.map(\.relativePath))))
        for (filename, bytes) in oldBytes {
            #expect(try Data(contentsOf: directory.appendingPathComponent(filename)) == bytes)
        }
        #expect(appended.allSatisfy { $0.sourcePage == 4 && $0.blockIDs == [next.id] })
    }

    @MainActor @Test func sourcePagesRemainAccurateWhenSeveralBlocksAreRendered() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TextBlock(sourcePage: 0, text: "The first source page has an independent evidence anchor.")
        let second = TextBlock(sourcePage: 1, text: "The next source page must not inherit the previous page anchor.")
        let pages = try PageRenderer().render(
            [BilingualBlock(block: first, translation: nil), BilingualBlock(block: second, translation: nil)],
            to: directory, prefix: "sources")
        #expect(pages.count == 2)
        #expect(pages.map(\.sourcePage) == [0, 1])
        #expect(pages.map(\.blockIDs) == [[first.id], [second.id]])
    }

    @Test func demoIsOriginalMultipageAndCanReflow() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("demo.pdf")
        try DemoPaper.write(to: input)
        let paper = try await PDFImporter(root: directory.appendingPathComponent("library")).importPDF(at: input)
        #expect(paper.title == "Understanding Attention")
        #expect(paper.pageCount >= 2)
        #expect(paper.canReflow)
        #expect(Set(paper.blocks.map(\.sourcePage)).count == paper.pageCount)
        #expect(paper.blocks.map(\.text).joined().contains("Understanding Attention"))
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PaperReader-PDFTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeFixture(at url: URL, title: String? = nil, draw: (CGContext) -> Void) throws {
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let info: CFDictionary? = title.map { [kCGPDFContextTitle as String: $0] as CFDictionary }
    guard let context = CGContext(url as CFURL, mediaBox: &bounds, info) else {
        throw ReaderError.message("Cannot create fixture")
    }
    context.beginPDFPage(nil)
    draw(context)
    context.endPDFPage()
    context.closePDF()
}

private func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 11, in context: CGContext) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let string = NSAttributedString(
        string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(string), context)
}
