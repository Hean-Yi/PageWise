import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Test func onDemandOCRReadsOriginalScannedPagesInSourceOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = try scannedFixture(
        root: root,
        pages: [
            [
                ("A careful reading preserves every sentence in this original example.", 710),
                ("The next sentence remains in the same reliable reading order.", 680),
            ],
            [("Another page provides independent evidence with its own page number.", 710)],
        ])
    let original = try Data(contentsOf: url)
    let document = try #require(PDFDocument(url: url))
    #expect((0..<document.pageCount).allSatisfy { (document.page(at: $0)?.string ?? "").isEmpty })
    let paper = try await PDFImporter(root: root).storeOriginal(at: url)
    #expect(paper.blocks.isEmpty)
    let evidence = try await ReflowEvidenceExtractor().extract(paper: paper, root: root)
    let prose = evidence.blocks.filter { $0.richContent?.requiresTranslation == true }
    try #require(prose.map(\.sourcePage) == [0, 0, 1])
    #expect(prose[0].text.contains("careful reading"))
    #expect(prose[1].text.contains("next sentence"))
    #expect(prose[2].text.contains("independent evidence"))
    #expect(prose.allSatisfy { $0.richContent?.html.contains("data-ocr-confidence") == true })
    #expect(!evidence.blocks.contains { $0.preservesSourcePage == true })
    #expect(evidence.warnings.contains { $0.contains("OCR") })
    #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == original)
    let folders = try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("Papers"), includingPropertiesForKeys: nil)
    #expect(folders.count == 1)
}

@Test func scannedFormulaIsPreservedLocallyAndNeverSentAsProse() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = try scannedFixture(
        root: root,
        pages: [
            [
                ("The paragraph before the equation remains readable and selectable.", 710),
                ("x = y + 2", 600),
                ("The paragraph after the equation keeps its original reading order.", 490),
            ]
        ])
    let page = try #require(PDFDocument(url: url)?.page(at: 0))
    let recovery = try #require(try PDFOCREvidence.recover(page, sourcePage: 7))
    #expect(recovery.blocks.allSatisfy { $0.sourcePage == 7 })
    let prose = recovery.blocks.filter { $0.richContent?.requiresTranslation == true }
    try #require(prose.count == 2)
    #expect(prose[0].text.contains("before the equation"))
    #expect(prose[1].text.contains("after the equation"))
    #expect(!prose.contains { $0.text.contains("=") || $0.text.contains("y +") })
    let image = try #require(recovery.blocks.first { $0.richContent?.isFigure == true })
    #expect(image.richContent?.html.contains("data:image/png;base64,") == true)
    #expect(image.richContent?.requiresTranslation == false)
    #expect(recovery.warning.contains("保留原图"))
}

@Test func uncertainAndOmittedOCRLinesRemainVisibleAsSourceCrops() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = try scannedFixture(
        root: root,
        pages: [
            [
                ("The reliable paragraph gives sufficient evidence for a local translation.", 710),
                ("This uncertain sentence must remain visible in its original form.", 600),
                ("A sentence omitted by recognition must also remain visible in the result.", 490),
            ]
        ])
    let page = try #require(PDFDocument(url: url)?.page(at: 0))
    let recognized = try VisionPDFTextRecognizer.recognize(page)
    let reliable = try #require(recognized.first { $0.text.contains("reliable paragraph") })
    let uncertain = try #require(recognized.first { $0.text.contains("uncertain sentence") })
    let recovery = try #require(
        try PDFOCREvidence.recover(
            page, sourcePage: 2,
            candidates: [
                reliable, PDFOCRLine(text: uncertain.text, bounds: uncertain.bounds, confidence: 0.2),
            ]))
    let prose = recovery.blocks.filter { $0.richContent?.requiresTranslation == true }
    try #require(prose.count == 1)
    #expect(prose[0].text.contains("reliable paragraph"))
    #expect(recovery.blocks.filter { $0.richContent?.isFigure == true }.count >= 2)
    #expect(recovery.blocks.allSatisfy { $0.sourcePage == 2 })
    #expect(recovery.warning.contains("未识别区域已保留原图"))
}

@Test func scannedGraphicKeepsLocalObjectAndSendsBodyToModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = try scannedFixture(
        root: root,
        pages: [
            [
                ("This paragraph appears above a graphic whose structure is not recognized.", 710)
            ]
        ], graphic: true)
    let paper = try await PDFImporter(root: root).storeOriginal(at: url)
    let evidence = try await ReflowEvidenceExtractor().extract(paper: paper, root: root)
    #expect(!evidence.blocks.contains { $0.preservesSourcePage == true })
    #expect(evidence.blocks.contains { $0.richContent?.requiresTranslation == true })
    #expect(evidence.blocks.contains { $0.richContent?.isFigure == true })
    #expect(evidence.warnings.contains { $0.contains("OCR") })
}

@Test func localOCRRejectsConflictingTextLayerAndRetainsAnnotations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("text-layer.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: 54, y: 700)
    CTLineDraw(
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "This visible paragraph provides the original reliable evidence.",
                attributes: [
                    .init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)
                ])), context)
    context.endPDFPage()
    context.closePDF()
    let document = try #require(PDFDocument(url: url))
    let page = try #require(document.page(at: 0))
    let native = try #require(PDFProcessor.positionedLines(on: page).rows.first?.first)
    let conflicting = PDFOCRLine(
        text: "This conflicting paragraph reports a completely different finding.", bounds: native.bounds, confidence: 1
    )
    #expect(try PDFOCREvidence.recover(page, sourcePage: 0, candidates: [conflicting]) == nil)
    let matching = PDFOCRLine(text: native.text, bounds: native.bounds, confidence: 1)
    page.rotation = 90
    #expect(try PDFOCREvidence.recover(page, sourcePage: 0, candidates: [matching]) == nil)
    page.rotation = 0
    page.addAnnotation(PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil))
    #expect(try PDFOCREvidence.recover(page, sourcePage: 0, candidates: [matching]) == nil)
}

@Test func twoColumnOCRWithMiddleEquationKeepsSourceInsteadOfInterleavingColumns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let left: [(String, CGFloat)] = [
        ("The first left sentence comes before the equation.", 710),
        ("Another left sentence continues this first paragraph.", 685),
        ("x = y + 2", 600),
        ("The next left sentence follows the retained equation.", 490),
        ("The last left sentence completes the entire left column.", 465),
    ]
    let right: [(String, CGFloat)] = [
        ("The first right sentence follows the whole left column.", 710),
        ("Another right sentence continues this separate column.", 685),
        ("The next right sentence continues its original argument.", 490),
        ("The last right sentence ends this original scanned page.", 465),
    ]
    let url = try scannedFixture(root: root, pages: [left], rightColumn: right, fontSize: 8)
    let original = try Data(contentsOf: url)
    let document = try #require(PDFDocument(url: url))
    let page = try #require(document.page(at: 0))
    #expect((page.string ?? "").isEmpty)
    // Known original geometry isolates the ordering policy from changes in Vision recognition.
    let candidates = [(left, CGFloat(54)), (right, CGFloat(330))].flatMap { lines, x in
        lines.map { text, y in
            PDFOCRLine(text: text, bounds: CGRect(x: x, y: y - 2, width: 220, height: 12), confidence: 1)
        }
    }
    #expect(try PDFOCREvidence.recover(page, sourcePage: 0, candidates: candidates) == nil)
    let paper = try await PDFImporter(root: root).storeOriginal(at: url)
    let evidence = try await ReflowEvidenceExtractor().extract(paper: paper, root: root)
    #expect(!evidence.blocks.contains { $0.preservesSourcePage == true })
    #expect(evidence.blocks.filter { $0.richContent?.requiresTranslation == true }.count >= 4)
    #expect(evidence.blocks.allSatisfy { $0.sourcePage == 0 && $0.reflowOrderGroup != nil })
    #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == original)
}

/// An original, generated bitmap embedded in PDF: there is intentionally no searchable text layer.
private func scannedFixture(
    root: URL, pages: [[(String, CGFloat)]], graphic: Bool = false,
    rightColumn: [(String, CGFloat)] = [], fontSize: CGFloat = 12
) throws -> URL {
    let url = root.appendingPathComponent("original-scanned-fixture.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pdf = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
    for lines in pages {
        let raster = try #require(
            CGContext(
                data: nil, width: 1_224, height: 1_584, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        raster.scaleBy(x: 2, y: 2)
        raster.setFillColor(CGColor(gray: 1, alpha: 1))
        raster.fill(bounds)
        raster.setFillColor(CGColor(gray: 0, alpha: 1))
        raster.textMatrix = .identity
        for (column, x) in [(lines, CGFloat(54)), (rightColumn, CGFloat(330))] {
            for (text, y) in column {
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                raster.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(
                    CTLineCreateWithAttributedString(
                        NSAttributedString(
                            string: text, attributes: [.init(kCTFontAttributeName as String): font])), raster)
            }
        }
        if graphic {
            raster.setStrokeColor(CGColor(gray: 0, alpha: 1))
            raster.setLineWidth(3)
            raster.strokeEllipse(in: CGRect(x: 130, y: 380, width: 280, height: 190))
        }
        let image = try #require(raster.makeImage())
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: bounds)
        pdf.endPDFPage()
    }
    pdf.closePDF()
    return url
}
