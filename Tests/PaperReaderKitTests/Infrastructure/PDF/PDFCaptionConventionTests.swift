import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Test func pdfCaptionsAcceptIndependentNumberAndTitleConventions() throws {
    let captions = [
        ("Table 17 Counts across seasons", "表 17", false),
        ("TABLE XIV", "表 XIV", true),
        ("Tab. S2 – Counts across seasons", "表 S2", false),
        ("Fig. A.3: Conditions in winter", "图 A.3", false),
        ("Fig.2b Conditions in winter", "图 2b", false),
    ]
    let url = try makeCaptionConventionPDF(captions.map { ($0.0, $0.2, true) })
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(document) {} }
    for (i, input) in captions.enumerated() {
        let page = try #require(document.page(at: i))
        let regions = try PDFCaptionRegionDetector.regions(on: page)
        #expect(regions.map(\.label) == [input.1])
        let source = try #require(regions.first?.sourceBounds)
        #expect(source.contains(CGRect(x: 86, y: 477, width: 250, height: 71)))
        let region = try #require(regions.first)
        #expect(!source.intersects(region.captionBounds))
        let marker = try #require(page.selection(for: region.captionRange)?.string)
        #expect(input.0.hasPrefix(marker))
    }
}

@Test func pdfCaptionDoesNotAttachNearbyDrawingsToBodyReferences() throws {
    let url = try makeCaptionConventionPDF([
        ("Table 1 shows the measurements across seasons.", false, true),
        ("Fig. 2 and Table 3 describe the observations.", false, true),
        ("Figure 3 (see Appendix B) explains the results.", false, true),
        ("Table 4 Results in winter", false, false),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(document) {} }
    for i in 0..<document.pageCount {
        let page = try #require(document.page(at: i))
        #expect(try PDFCaptionRegionDetector.regions(on: page).isEmpty)
        #expect(!(try PDFSentenceExtractor.extractPage(url: url, pageIndex: i)).sentences.isEmpty)
    }
}

@Test func pdfCaptionSeparatesWrappedHeadingFromTableHeaderAndFollowingSection() throws {
    let url = try captionPDF(pages: 1) { _, context in
        draw("Table S1. Seasonal measurements in the field", on: context, x: 78, y: 645, size: 13)
        draw("reported from five field stations in the experiment.", on: context, x: 78, y: 630)
        draw("Details", on: context, x: 78, y: 617)
        draw("are given separately.", on: context, x: 115, y: 617)
        context.fill(CGRect(x: 78, y: 627.6, width: 32, height: 0.5))
        for y in [614, 595, 530] { context.fill(CGRect(x: 100, y: y, width: 224, height: 1)) }
        draw("Season                      Days                     Samples", on: context, x: 102, y: 599)
        draw("Winter                           90                            39", on: context, x: 102, y: 582)
        draw("Spring                           92                            51", on: context, x: 102, y: 567)
        draw("Summer                        92                            64", on: context, x: 102, y: 552)
        draw("Autumn                          91                            76", on: context, x: 102, y: 538)
        draw("2.3 Seasonal trends", on: context, x: 78, y: 515)
        draw(
            "Observations from a later season corroborate the measurements taken during spring.", on: context, x: 78,
            y: 502)
        draw(
            "These stations are on the opposite side of the ridge and record the same increase.", on: context, x: 78,
            y: 489)
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(document) {} }
    let page = try #require(document.page(at: 0))
    let region = try #require(try PDFCaptionRegionDetector.regions(on: page).first)
    let content = try #require(region.sourceBounds.flatMap { page.selection(for: $0)?.string })
    #expect(content.contains("Season"))
    #expect(content.contains("Autumn"))
    #expect(!content.contains("field stations"))
    #expect(!content.contains("Details"))
    #expect(!content.contains("Seasonal trends"))
}

@Test func pdfCaptionAssignsTwoStackedFiguresUsingTheirSeparateMultiLineCaptions() throws {
    let url = try captionPDF(pages: 1) { _, context in
        for y in [575, 454] {
            context.fill(CGRect(x: 94, y: y, width: 140, height: 62))
        }
        draw("Fig. 1 Diagram of the station during winter", on: context, x: 78, y: 554, size: 12)
        draw("with labels indicating the inlet and outlet.", on: context, x: 78, y: 542)
        draw("Fig. 2 Diagram of the station during summer", on: context, x: 78, y: 430, size: 12)
        draw("with the internal drainage lines visible.", on: context, x: 78, y: 418)
        draw("The following section explains the observed differences in seasonal runoff.", on: context, x: 78, y: 394)
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let doc = try #require(PDFDocument(url: url))
    defer { withExtendedLifetime(doc) {} }
    let page = try #require(doc.page(at: 0))
    let regions = try PDFCaptionRegionDetector.regions(on: page)
    #expect(regions.map(\.label) == ["图 1", "图 2"])
    let bounds = try regions.map { try #require($0.sourceBounds) }
    #expect(bounds[0].contains(CGRect(x: 95, y: 575, width: 139, height: 62)))
    #expect(bounds[1].contains(CGRect(x: 95, y: 454, width: 139, height: 62)))
    #expect(!bounds[0].intersects(bounds[1]))
    #expect(bounds.allSatisfy { page.selection(for: $0)?.string?.isEmpty != false })
}

private func makeCaptionConventionPDF(_ captions: [(String, Bool, Bool)]) throws -> URL {
    try captionPDF(pages: captions.count) { index, context in
        let (caption, detached, hasTable) = captions[index]
        draw("The weather station measures the conditions.", on: context, x: 85, y: 640)
        if detached {
            draw(caption, on: context, x: 215, y: 579, centered: true)
            draw("MEASUREMENTS ACROSS SEASONS", on: context, x: 215, y: 568, centered: true)
        } else {
            draw(caption, on: context, x: 85, y: 575)
        }
        if hasTable {
            for y in [548, 526, 477] { context.fill(CGRect(x: 85, y: y, width: 252, height: 1)) }
            for (key, value, y) in [("Season", "Days", 532), ("Winter", "93", 505), ("Summer", "87", 484)] {
                draw(key, on: context, x: 89, y: CGFloat(y))
                draw(value, on: context, x: 241, y: CGFloat(y))
            }
        }
        draw("A following paragraph discusses the annual observations.", on: context, x: 85, y: 410)
    }
}

private func captionPDF(pages: Int, paint: (Int, CGContext) -> Void) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var box = CGRect(x: 0, y: 0, width: 500, height: 700)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for page in 0..<pages {
        context.beginPDFPage(nil)
        paint(page, context)
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

private func draw(
    _ text: String, on context: CGContext, x: CGFloat, y: CGFloat, size: CGFloat = 10, centered: Bool = false
) {
    let font = CTFontCreateWithName("Times-Roman" as CFString, size, nil)
    let run = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: centered ? x - CTLineGetTypographicBounds(run, nil, nil, nil) / 2 : x, y: y)
    CTLineDraw(run, context)
}
