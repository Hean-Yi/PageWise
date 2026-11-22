import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import PaperReaderKit

@Test func pdfTableExtractorPreservesNumericCellsAndExponents() throws {
    let data = try makeTablePDF()
    let document = try #require(PDFDocument(data: data))
    defer { withExtendedLifetime(document) {} }
    let page = try #require(document.page(at: 0))
    let table = try #require(PDFTableExtractor.extract(on: page, in: tableBody))
    #expect(table.header == ["Model setting", "Trial A", "Trial B"])
    #expect(
        table.rows == [
            ["Batch size", "1,024", "256"],
            ["Precision", "10⁻³", "0.05"],
            ["Seed (H_{Q})", "17", "41"],
        ])
    let emphasized = try #require(table.styledCells.first { $0.row == 1 && $0.column == 1 })
    #expect(emphasized.runs.contains { $0.text == "1,024" && $0.bold && $0.italic })
    let raised = try #require(table.styledCells.first { $0.row == 2 && $0.column == 1 })
    #expect(raised.runs.filter { $0.baseline == .superscript }.map(\.text).joined() == "−3")
    let lowered = try #require(table.styledCells.first { $0.row == 3 && $0.column == 0 })
    #expect(lowered.runs.filter { $0.baseline == .subscript }.map(\.text).joined() == "Q")
}

@Test func pdfTableExtractorKeepsIncompleteAndGraphicalTablesAsSourceCrops() throws {
    let data = try makeTablePDF()
    let document = try #require(PDFDocument(data: data))
    defer { withExtendedLifetime(document) {} }
    // A missing cell, an extra graphical mark, and a grouped header each require the published layout.
    for index in 1...3 {
        let page = try #require(document.page(at: index))
        #expect(PDFTableExtractor.extract(on: page, in: tableBody) == nil)
    }
}

private let tableBody = CGRect(x: 60, y: 504, width: 280, height: 89)

private func makeTablePDF() throws -> Data {
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data))
    var box = CGRect(x: 0, y: 0, width: 480, height: 640)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
    let smallFont = CTFontCreateWithName("Helvetica" as CFString, 7, nil)
    let emphasis = CTFontCreateWithName("Helvetica-BoldOblique" as CFString, 10, nil)
    func text(_ string: String, _ x: CGFloat, _ y: CGFloat, small: Bool = false, emphasized: Bool = false) {
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        let value = NSAttributedString(
            string: string,
            attributes: [.init(kCTFontAttributeName as String): emphasized ? emphasis : (small ? smallFont : font)])
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
    }
    for index in 0...3 {
        context.beginPDFPage(nil)
        for y: CGFloat in [590, 569, 506] {
            context.fill(CGRect(x: 62, y: y, width: 276, height: 0.7))
        }
        text("Model setting", 65, 577)
        if index == 3 {
            text("All trials", 224, 577)
        } else {
            text("Trial A", 200, 577)
            text("Trial B", 282, 577)
        }
        text("Batch size", 65, 553)
        text("1,024", 200, 553, emphasized: true)
        text("256", 282, 553)
        text("Precision", 65, 537)
        text("10", 200, 537)
        text("−3", 211.1, 541, small: true)
        text("0.05", 282, 537)
        text("Seed (H", 65, 518)
        text("Q", 100.55, 516.5, small: true)
        text(")", 106, 518)
        if index != 1 { text("17", 200, 518) }
        text("41", 282, 518)
        if index == 2 { context.fillEllipse(in: CGRect(x: 315, y: 519, width: 7, height: 7)) }
        text("Table 1: Training settings.", 60, 480)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

@Test func pdfTableExtractorProvesTheFullCoverageOfGroupedHeaders() throws {
    let data = try groupedTablePDF()
    let document = try #require(PDFDocument(data: data))
    defer { withExtendedLifetime(document) {} }
    let region = CGRect(x: 22, y: 505, width: 310, height: 87)
    let page = try #require(document.page(at: 0))
    let table = try #require(PDFTableExtractor.extract(on: page, in: region))
    #expect(table.header == ["Variant", "Prefill", "Decode", "16K", "32K†"])
    #expect(
        table.headerRows.map { $0.map(\.text) } == [
            ["Variant", "Latency", "Retrieval"], ["Prefill", "Decode", "16K", "32K†"],
        ])
    #expect(table.headerRows[0].map(\.rowSpan) == [2, 1, 1])
    #expect(table.headerRows[0].map(\.columnSpan) == [1, 2, 2])
    #expect(table.headerRows[1].map(\.column) == [1, 2, 3, 4])
    #expect(table.headerRows[1].last?.runs.last?.baseline == .superscript)
    #expect(table.rows == [["Start", "12.10", "64.09", "0.90", "0.98"], ["Final", "11.50", "60.19", "0.98", "1.00"]])
    #expect(table.sourceCellBounds.map(\.count) == [3, 4, 5, 5])
    #expect(table.sourceCellBounds.flatMap { $0 }.allSatisfy { !$0.isEmpty && region.contains($0) })
    let emphasized = try #require(table.styledCells.first { $0.row == 2 && $0.column == 4 })
    #expect(emphasized.runs.allSatisfy { $0.bold })
    // Omitted group underline, missing body value, extra vector glyph in a body cell.
    for index in 1...3 {
        let invalid = try #require(document.page(at: index))
        #expect(PDFTableExtractor.extract(on: invalid, in: region) == nil)
    }
}

private func groupedTablePDF() throws -> Data {
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data))
    var box = CGRect(x: 0, y: 0, width: 480, height: 640)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    func text(_ value: String, centered x: CGFloat, baseline y: CGFloat, size: CGFloat = 9, bold: Bool = false) {
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: value, attributes: [.init(kCTFontAttributeName as String): font]))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x - CTLineGetTypographicBounds(line, nil, nil, nil) / 2, y: y)
        CTLineDraw(line, context)
    }
    for variant in 0...3 {
        context.beginPDFPage(nil)
        for y: CGFloat in [589, 550, 508] {
            context.fill(CGRect(x: 25, y: y, width: 304, height: 0.8))
        }
        text("Variant", centered: 50, baseline: 566)
        text("Latency", centered: 125, baseline: 574)
        text("Retrieval", centered: 262, baseline: 574)
        context.fill(CGRect(x: 86, y: 568, width: 78, height: 0.6))
        if variant != 1 { context.fill(CGRect(x: 215, y: 568, width: 94, height: 0.6)) }
        text("Prefill", centered: 100, baseline: 557)
        text("Decode", centered: 150, baseline: 557)
        text("16K", centered: 236, baseline: 557)
        text("32K", centered: 288, baseline: 557)
        text("†", centered: 298, baseline: 560.5, size: 6)
        for (row, fields) in [
            ["Start", "12.10", "64.09", "0.90", "0.98"], ["Final", "11.50", "60.19", "0.98", "1.00"],
        ].enumerated() {
            for (col, value) in fields.enumerated() where variant != 2 || row != 1 || col != 2 {
                text(
                    value, centered: [50, 100, 150, 236, 288][col], baseline: row == 0 ? 535 : 517,
                    bold: row == 1 && col == 4)
            }
        }
        if variant == 3 { context.fillEllipse(in: CGRect(x: 176, y: 520, width: 5, height: 5)) }
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}
