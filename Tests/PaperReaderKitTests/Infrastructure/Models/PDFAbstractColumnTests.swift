import CoreGraphics
import Testing

@testable import PaperReaderKit

@Test func titlePagePreviewReadsTheWholeAbstractColumnAndSkipsPublicationMetadata() throws {
    func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> PDFAbstractColumn.Line {
        .init(text: text, bounds: CGRect(x: x, y: y, width: width, height: 10))
    }
    let rows = [
        line("Abstract", x: 180, y: 440, width: 51),
        line("A local trial compared readings across two seasons.", x: 180, y: 418, width: 340),
        line("Copyright and contact information", x: 36, y: 413, width: 125),
        line("Both sites reported a smaller difference in winter.", x: 180, y: 402, width: 342),
        line("Published on October 1", x: 36, y: 401, width: 125),
        line("Unmeasured conditions could have influenced the result.", x: 180, y: 386, width: 349),
        line("Introduction", x: 180, y: 310, width: 92),
        line("The study area includes two sites.", x: 180, y: 292, width: 274),
    ]
    #expect(
        PDFAbstractColumn.text(in: rows.shuffled())
            == "A local trial compared readings across two seasons. Both sites reported a smaller difference in winter. Unmeasured conditions could have influenced the result."
    )
    #expect(PDFAbstractColumn.text(in: Array(rows.prefix(6))) == nil)
}
