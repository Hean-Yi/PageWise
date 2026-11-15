import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Test func regionalPDFReflowsProseAndKeepsFigureAndEquationExactlyOnce() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("regional.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    regionalText("1 Introduction", y: 740, size: 18, context: context)
    regionalText("Readable prose before the figure remains real selectable text.", y: 700, context: context)
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.strokeEllipse(in: CGRect(x: 100, y: 440, width: 200, height: 170))
    regionalText("FIGURE_LABEL", y: 490, context: context)
    regionalText("REMOTE LEGEND", y: 632, context: context)
    regionalText("Figure 1. Local drawing with its original label.", y: 412, context: context)
    regionalText("The discussion after the drawing is a separate paragraph.", y: 370, context: context)
    regionalText("x = y + 2", y: 300, context: context)
    regionalText("The final paragraph must remain present exactly once.", y: 240, context: context)
    context.endPDFPage()
    context.closePDF()
    let document = try #require(PDFDocument(url: file))
    let page = try #require(document.page(at: 0))
    let result = try PDFProcessor.extract(from: document, preservingComplexPages: true)
    #expect(result.canReflow)
    #expect(!result.blocks.contains { $0.preservesSourcePage == true })
    #expect(result.blocks.contains { $0.text.contains("Readable prose") && $0.richContent?.isFigure != true })
    #expect(result.blocks.contains { $0.text.contains("final paragraph") && $0.richContent?.isFigure != true })
    let crop = try #require(result.blocks.first { $0.text.contains("FIGURE_LABEL") })
    #expect(crop.richContent?.isFigure == true)
    #expect(crop.text.contains("REMOTE LEGEND"))
    #expect(crop.richContent?.requiresTranslation == false)
    #expect(result.blocks.first { $0.text.contains("x = y") }?.richContent?.requiresTranslation == false)
    #expect(
        PDFRegionalReflow.characters(page.string ?? "")
            == PDFRegionalReflow.characters(result.blocks.map(\.text).joined()))
    let html = result.blocks.compactMap { $0.richContent?.html }.joined()
    #expect(html.contains("<h2>1 Introduction</h2>"))
    #expect(!html.contains("source-page"))
}

@Test func regionalPDFDoesNotDropExistingAnnotationsOrScannedPages() throws {
    let document = PDFDocument()
    let page = PDFPage()
    page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
    document.insert(page, at: 0)
    #expect(try PDFRegionalReflow.recover(page, sourcePage: 0) == nil)
    let annotation = PDFAnnotation(
        bounds: CGRect(x: 50, y: 100, width: 100, height: 30), forType: .text, withProperties: nil)
    page.addAnnotation(annotation)
    #expect(try PDFRegionalReflow.recover(page, sourcePage: 0) == nil)
}

@Test func regionalTwoColumnEquationRetainsSourceWithoutPublishingCrossColumnOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("two-column-equation.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    for (text, y) in [
        ("The first left sentence comes before the equation.", 710.0),
        ("Another left sentence continues this first paragraph.", 685.0),
        ("The next left sentence follows the retained equation.", 490.0),
        ("The last left sentence completes the entire left column.", 465.0),
    ] {
        regionalText(text, y: y, size: 8, x: 54, context: context)
    }
    regionalText("z = ∑ x + y", y: 600, size: 12, x: 54, context: context)
    for (text, y) in [
        ("The first right sentence follows the whole left column.", 710.0),
        ("Another right sentence continues this separate column.", 685.0),
        ("The next right sentence continues its original argument.", 490.0),
        ("The last right sentence ends this original source page.", 465.0),
    ] {
        regionalText(text, y: y, size: 8, x: 330, context: context)
    }
    context.endPDFPage()
    context.closePDF()
    let original = try Data(contentsOf: file)
    let document = try #require(PDFDocument(url: file))
    let page = try #require(document.page(at: 0))
    let source = try #require(page.string)
    #expect(source.contains("∑"))
    #expect(try PDFRegionalReflow.recover(page, sourcePage: 0) == nil)
    let result = try PDFProcessor.extract(from: document, preservingComplexPages: true)
    #expect(result.blocks.count == 1)
    #expect(result.blocks.first?.preservesSourcePage == true)
    #expect(result.blocks.first?.sourcePage == 0)
    #expect(result.blocks.first?.text == source)
    #expect(!result.canReflow)
    #expect(try Data(contentsOf: file) == original)
}

private func regionalText(_ text: String, y: CGFloat, size: CGFloat = 12, x: CGFloat = 54, context: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        .init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil)
    ]
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
}

@Test func regionalRepairPreservesPublishedAnchorsAndOriginalBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("source.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    regionalText("A protected paragraph keeps its exact annotation anchor.", y: 700, context: context)
    context.endPDFPage()
    context.beginPDFPage(nil)
    regionalText("Body prose before a locally retained graphic remains readable.", y: 700, context: context)
    context.strokeEllipse(in: CGRect(x: 100, y: 400, width: 200, height: 150))
    regionalText("Body prose after the graphic must appear once and only once.", y: 300, context: context)
    context.endPDFPage()
    context.closePDF()
    var paper = try await PDFImporter(root: root).importPDF(at: file, preservingComplexPages: true)
    let document = try #require(PDFDocument(url: file))
    var retained = TextBlock(sourcePage: 1, text: document.page(at: 1)?.string ?? "")
    retained.preservesSourcePage = true
    let protected = try #require(paper.blocks.first)
    paper.blocks = [protected, retained]
    let store = HTMLReadingStore()
    paper.htmlReading = try await store.prepareOriginal(paper: paper, root: root)
    let artifact = try #require(paper.htmlReading)
    let old = try String(contentsOf: root.appendingPathComponent(artifact.relativePath), encoding: .utf8)
    let bytes = try Data(contentsOf: root.appendingPathComponent(paper.originalPath))
    let rejected = try await store.repairPDFRegions(paper: paper, root: root, protectedKeys: [retained.id.uuidString])
    #expect(rejected.changedKeys.isEmpty)
    #expect(rejected.paper.htmlReading == artifact)
    let result = try await store.repairPDFRegions(paper: paper, root: root, protectedKeys: [protected.id.uuidString])
    #expect(result.repairedPages == 1)
    #expect(result.changedKeys == [retained.id.uuidString])
    #expect(!result.paper.blocks.contains { $0.preservesSourcePage == true })
    let newArtifact = try #require(result.paper.htmlReading)
    let new = try String(contentsOf: root.appendingPathComponent(newArtifact.relativePath), encoding: .utf8)
    #expect(
        String(old[try HTMLReadingStore.sectionRange(protected.id, in: old)])
            == String(new[try HTMLReadingStore.sectionRange(protected.id, in: new)]))
    #expect(try String(contentsOf: root.appendingPathComponent(artifact.relativePath), encoding: .utf8) == old)
    #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == bytes)
    #expect(
        PDFRegionalReflow.characters(result.paper.blocks.map(\.text).joined())
            == PDFRegionalReflow.characters(paper.blocks.map(\.text).joined()))
    let again = try await store.repairPDFRegions(
        paper: result.paper, root: root, protectedKeys: [protected.id.uuidString])
    #expect(again.changedKeys.isEmpty)
    #expect(again.paper.htmlReading == newArtifact)
    try HTMLReadingStore.cleanup(root: root, paper: result.paper)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(artifact.relativePath).path))
    #expect(
        newArtifact.assets.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })
}

@Test func regionalBibliographyRestoresAuthorsWithoutMatchingCitationLinksAsLists() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("references.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    regionalText("References", y: 700, context: context)
    regionalText("Alice Example and Bob Example. Reliable regional reading. 2026.", y: 660, context: context)
    regionalText("Alice Example and Carol Example. Stable citation identities. 2025.", y: 630, context: context)
    regionalText("APPENDIX", y: 580, context: context)
    regionalText("This content must not become another reference.", y: 540, context: context)
    context.endPDFPage()
    context.closePDF()
    var intro = TextBlock(sourcePage: 0, text: "As described by Example et al.")
    intro.richContent = RichContent(
        html: "<p>As described by <a href='#ref-bib.one'>Example et al.</a></p>", translationInput: intro.text,
        mathematics: [:], mathDescriptions: [:])
    var bibliography = TextBlock(sourcePage: 0, text: "Abbreviated references")
    bibliography.richContent = RichContent(
        html:
            "<ul><li id='ref-bib.one'><span>Reliable regional reading.</span><a href='#cite-one'>Back</a></li><li id='ref-bib.two'><span>Stable citation identities.</span></li></ul>",
        translationInput: "", mathematics: [:], mathDescriptions: [:])
    let document = try #require(PDFDocument(url: file))
    let restored = try PDFBibliographyRecovery.restore(in: [intro, bibliography], document: document)
    #expect(restored[0].richContent?.html == intro.richContent?.html)
    #expect(restored[1].text.contains("Bob Example"))
    #expect(restored[1].text.contains("Carol Example"))
    #expect(!restored[1].text.contains("APPENDIX"))
    #expect(restored[1].richContent?.html.contains("ref-bib.one") == true)
    #expect(restored[1].richContent?.html.contains("#cite-one") == true)
}

@Test(arguments: [8.0, 12.0, 16.0], [0.6, 1.2, 2.2])
func regionalRunInHeadingIsNotMistakenForTwoColumns(size: Double, gapScale: Double) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("run-in.pdf")
    var bounds = CGRect(x: 0, y: 0, width: CGFloat(size * 51), height: 792)
    let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    regionalText(
        "A full width paragraph establishes the single column body of this original fixture.", y: 700, size: size,
        context: context)
    let title = "Run-in heading"
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: title, attributes: [.init(kCTFontAttributeName as String): font]))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    regionalText(title, y: 660, size: size, context: context)
    regionalText(
        "The explanation continues on this same baseline across the page.", y: 660, size: size,
        x: 54 + width + size * gapScale, context: context)
    regionalText("Run-in heading", y: 620, size: size, context: context)
    regionalText(
        "Another explanation continues across the center of the page.", y: 620, size: size,
        x: 54 + width + size * gapScale, context: context)
    regionalText(
        "The remaining body text should never be rendered as one large screenshot.", y: 580, size: size,
        context: context)
    context.endPDFPage()
    context.closePDF()
    let document = try #require(PDFDocument(url: file))
    let page = try #require(document.page(at: 0))
    let blocks = try #require(try PDFRegionalReflow.recover(page, sourcePage: 0))
    #expect(blocks.allSatisfy { $0.richContent?.isFigure != true })
    #expect(blocks.contains { $0.text.contains("Run-in heading The explanation") })
    #expect(
        PDFRegionalReflow.characters(page.string ?? "") == PDFRegionalReflow.characters(blocks.map(\.text).joined()))
}

@Test(arguments: [true, false]) func regionalSourceIdentityUsesVersionedMarginOnly(inMargin: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("identifier.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    regionalText("arXiv:2401.12345v3 [cs.CL]", y: inMargin ? 754 : 400, context: context)
    regionalText(
        "Ordinary paragraph content must remain fully present in the reading result.", y: 600, context: context)
    context.endPDFPage()
    context.closePDF()
    let document = try #require(PDFDocument(url: file))
    let candidate = PDFSourceIdentity.arxivCandidate(document: document, title: "Original test fixture")
    #expect((candidate != nil) == inMargin)
    if inMargin { #expect(candidate?.id == "https://arxiv.org/abs/2401.12345v3") }
    let page = try #require(document.page(at: 0))
    let corpus = PDFTextCoverage.normalized(page.string ?? "")
    #expect(PDFTextCoverage.covers(page, sourcePage: 0, corpus: corpus, repeatedMargins: []))
    #expect(
        !PDFTextCoverage.covers(
            page, sourcePage: 0, corpus: corpus.replacingOccurrences(of: "fullypresent", with: ""), repeatedMargins: [])
    )
}

private struct OfflineRepairDiscovery: PaperDiscovery {
    func search(_ query: String) async throws -> [PaperCandidate] { [] }
    func download(_ candidate: PaperCandidate) async throws -> URL { throw ReaderError.message("Offline fixture") }
}

@Test func regionalRepairIncludesLegacyOriginalOnlyPapers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("source.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    regionalText("An original-only paper still deserves selectable reflowed body text.", y: 700, context: context)
    context.strokeEllipse(in: CGRect(x: 100, y: 400, width: 200, height: 100))
    regionalText("The paragraph after the drawing must survive the repair.", y: 300, context: context)
    context.endPDFPage()
    context.closePDF()
    let paper = try await PDFImporter(root: root).importPDF(at: file)
    #expect(paper.htmlReading == nil)
    let original = try Data(contentsOf: root.appendingPathComponent(paper.originalPath))
    let repaired = try await HTMLReadingStore().repairPDFRegions(
        paper: paper, root: root, protectedKeys: [], discovery: OfflineRepairDiscovery())
    #expect(repaired.paper.htmlReading?.fullSource == true)
    #expect(repaired.paper.id == paper.id)
    #expect(repaired.paper.blocks.contains { $0.text.contains("original-only") && $0.richContent?.isFigure != true })
    #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == original)
}

@Test func unavailableOnlineSourceCannotDowngradePublishedSemanticHTML() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("source.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    regionalText(
        "Reliable semantic prose stays readable even when the network source is unavailable.", y: 700, context: context)
    context.strokeEllipse(in: CGRect(x: 100, y: 400, width: 200, height: 100))
    context.endPDFPage()
    context.closePDF()
    var paper = try await PDFImporter(root: root).importPDF(at: file)
    var block = TextBlock(sourcePage: 0, text: "Reliable semantic prose stays readable.")
    block.richContent = RichContent(
        html: "<p>Reliable semantic prose stays readable.</p>", translationInput: block.text, mathematics: [:],
        mathDescriptions: [:])
    paper.blocks = [block]
    paper.htmlReading = try await HTMLReadingStore().prepareOriginal(paper: paper, root: root)
    let artifact = try #require(paper.htmlReading)
    let bytes = try Data(contentsOf: root.appendingPathComponent(artifact.relativePath))
    let repaired = try await HTMLReadingStore().repairPDFRegions(
        paper: paper, root: root, protectedKeys: [], discovery: OfflineRepairDiscovery())
    #expect(repaired.changedKeys.isEmpty)
    #expect(repaired.paper.htmlReading == paper.htmlReading)
    #expect(try Data(contentsOf: root.appendingPathComponent(artifact.relativePath)) == bytes)
}
