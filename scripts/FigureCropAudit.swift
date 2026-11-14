import Foundation
import PDFKit

@testable import PaperReaderKit

struct AuditRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ rect: CGRect) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
    }
}
struct CropTruth: Decodable {
    var caption: String
    /// Human-labelled page number, starting at one. Rectangles use unrotated PDF point coordinates.
    var page: Int
    var expected: AuditRect
    var body: [AuditRect]?
}
struct CropAuditRow: Codable {
    var index: Int
    var expectedPage: Int
    var locatedPage: Int?
    var outcome: String
    var crop: AuditRect?
    var coverage: Double?
    var areaRatio: Double?
    var reason: String?
}
struct CropAuditReport: Codable {
    var total: Int
    var geometricPasses: Int
    var wrongCrops: Int
    var refusals: Int
    var sampleSuccessRate: Double
    var rows: [CropAuditRow]
}

guard CommandLine.arguments.count == 4 else {
    throw ReaderError.message("Usage: audit-figure-crops.sh original.pdf truth.json NEW_OUTPUT_DIRECTORY")
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let truth = try JSONDecoder().decode(
    [CropTruth].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
guard !truth.isEmpty, truth.count <= 500, let document = PDFDocument(url: source), !document.isLocked,
    !FileManager.default.fileExists(atPath: output.path)
else { throw ReaderError.message("Invalid PDF/manifest, or output directory already exists.") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var rows: [CropAuditRow] = []
for (index, item) in truth.enumerated() {
    guard item.page > 0, item.page <= document.pageCount, item.expected.width > 0, item.expected.height > 0,
        [item.expected.x, item.expected.y, item.expected.width, item.expected.height].allSatisfy(\.isFinite)
    else { throw ReaderError.message("Invalid labelled page or bounds at item \(index + 1).") }
    let located = try PDFFigureCropper.captionPage(item.caption, in: document)
    var reason: String?
    var recovery: PDFFigureCropper.Recovery?
    if let located, let page = document.page(at: located) {
        recovery = try PDFFigureCropper.recover(caption: item.caption, from: page, diagnostic: { reason = $0 })
    }
    guard let recovery else {
        rows.append(
            CropAuditRow(
                index: index + 1, expectedPage: item.page, locatedPage: located.map { $0 + 1 },
                outcome: "refused", reason: reason ?? "caption not uniquely located"))
        continue
    }
    let expected = item.expected.rect
    let intersection = recovery.bounds.intersection(expected)
    let coverage =
        intersection.isNull ? 0 : intersection.width * intersection.height / (expected.width * expected.height)
    let areaRatio = recovery.bounds.width * recovery.bounds.height / (expected.width * expected.height)
    let bodyOverlap = (item.body ?? []).contains {
        let overlap = $0.rect.intersection(recovery.bounds)
        return !overlap.isNull && overlap.width * overlap.height > 1
    }
    let passed = located == item.page - 1 && coverage >= 0.995 && areaRatio <= 1.5 && !bodyOverlap
    rows.append(
        CropAuditRow(
            index: index + 1, expectedPage: item.page, locatedPage: located.map { $0 + 1 },
            outcome: passed ? "geometric_pass" : "wrong_crop", crop: AuditRect(recovery.bounds), coverage: coverage,
            areaRatio: areaRatio))
    let encoded = recovery.image.dataURI.components(separatedBy: ",").last ?? ""
    guard let bytes = Data(base64Encoded: encoded) else { throw ReaderError.message("Invalid generated image") }
    try bytes.write(to: output.appendingPathComponent("figure-\(index + 1).png"), options: .withoutOverwriting)
}
let passes = rows.filter { $0.outcome == "geometric_pass" }.count
let report = CropAuditReport(
    total: rows.count, geometricPasses: passes,
    wrongCrops: rows.filter { $0.outcome == "wrong_crop" }.count,
    refusals: rows.filter { $0.outcome == "refused" }.count,
    sampleSuccessRate: Double(passes) / Double(rows.count), rows: rows)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: output.appendingPathComponent("report.json"), options: .withoutOverwriting)
print(
    "Figures: \(report.total); geometry passes: \(passes); wrong crops: \(report.wrongCrops); refused: \(report.refusals)"
)
print("Sample success rate: \(report.sampleSuccessRate). This is not a guarantee for unseen papers; inspect the PNGs.")
