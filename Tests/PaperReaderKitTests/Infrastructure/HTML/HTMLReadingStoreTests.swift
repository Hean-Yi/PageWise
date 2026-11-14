import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import PaperReaderKit

@Test func htmlReadingAppendsStableSectionsDeduplicatesSVGAndCleansOnlyUnreferencedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let svg =
        "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'><text x='10' y='50'>KEEP_LABEL</text></svg>"
    let uri = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    func block(_ text: String) -> TextBlock {
        var block = TextBlock(sourcePage: 0, text: text)
        block.richContent = RichContent(
            html: "<p>\(text) <math><mi>x</mi></math></p><img src='\(uri)' width='200' height='100'>",
            translationInput: text + " [[MATH_1]]", mathematics: ["[[MATH_1]]": "<math><mi>x</mi></math>"],
            mathDescriptions: ["[[MATH_1]]": "x"])
        return block
    }
    let first = block("First original")
    let second = block("Second original")
    var paper = Paper(
        title: "Local HTML", digest: "fixture", originalPath: "original.pdf", pageCount: 1,
        blocks: [first, second], warnings: [], canReflow: true)
    let store = HTMLReadingStore()
    let initial = try await store.append(
        [BilingualBlock(block: first, translation: "第一段 [[MATH_1]]")], to: nil, paper: paper, root: root)
    paper.htmlReading = initial
    let initialURL = root.appendingPathComponent(initial.relativePath)
    let originalBytes = try Data(contentsOf: initialURL)
    let next = try await store.append(
        [BilingualBlock(block: second, translation: "第二段 [[MATH_1]]")], to: initial, paper: paper, root: root)
    #expect(next.assets == initial.assets)
    #expect(next.sections.map(\.id) == [first.id, second.id])
    #expect(try Data(contentsOf: initialURL) == originalBytes)
    let append = try await store.appendedContent(
        at: root.appendingPathComponent(next.relativePath), excluding: [first.id.uuidString])
    #expect(!append.contains("First original"))
    #expect(append.contains("Second original"))
    let finalHTML = try String(contentsOf: root.appendingPathComponent(next.relativePath), encoding: .utf8)
    #expect(finalHTML.contains("<math>"))
    #expect(finalHTML.contains("第二段"))
    #expect(!finalHTML.contains("base64"))
    #expect(!finalHTML.contains("column-width"))
    #expect(try String(contentsOf: root.appendingPathComponent(next.assets[0]), encoding: .utf8) == svg)
    paper.htmlReading = next
    try HTMLReadingStore.cleanup(root: root, paper: paper)
    #expect(!FileManager.default.fileExists(atPath: initialURL.path))
    let folder = root.appendingPathComponent(next.relativePath).deletingLastPathComponent()
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    let reference = try #require(PaperPageLocator.resolve(pageKey: first.id.uuidString, in: paper))
    #expect(reference.pageIndex == 0)
    #expect(PaperPageLocator.sourcePage(for: reference, in: paper) == 0)
    await #expect(throws: (any Error).self) {
        try await store.append([BilingualBlock(block: first, translation: nil)], to: next, paper: paper, root: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
}

@Test func htmlReadingFailedBatchDoesNotReplacePublishedContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var paper = Paper(
        title: "Failure", digest: "fixture", originalPath: "original.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: true)
    let first = TextBlock(sourcePage: 0, text: "Saved evidence")
    let store = HTMLReadingStore()
    let artifact = try await store.append(
        [BilingualBlock(block: first, translation: nil)], to: nil, paper: paper, root: root)
    paper.htmlReading = artifact
    var missing = TextBlock(sourcePage: 0, text: "Missing image")
    missing.richContent = RichContent(
        html: "<img src='https://example.com/private.png'>", translationInput: "", mathematics: [:],
        mathDescriptions: [:])
    await #expect(throws: (any Error).self) {
        try await store.append(
            [BilingualBlock(block: missing, translation: nil)], to: artifact, paper: paper, root: root)
    }
    let abandoned = try await store.append(
        [BilingualBlock(block: TextBlock(sourcePage: 0, text: "Uncommitted"), translation: nil)], to: artifact,
        paper: paper, root: root)
    try HTMLReadingStore.cleanup(root: root, paper: paper)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(abandoned.relativePath).path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(artifact.relativePath).path))
    var state = LibraryState()
    state.papers = [paper]
    let roundtrip = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
    #expect(roundtrip.papers[0].htmlReading == artifact)
    state.papers[0].htmlReading = nil
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    object["version"] = 5
    let migrated = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(migrated.version == 6)
    #expect(migrated.papers[0].id == paper.id)
    #expect(migrated.papers[0].htmlReading == nil)
}

@Test @MainActor func htmlReadingRetainsComplexOriginalPageAsAnExplicitImage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = root.appendingPathComponent("original.pdf")
    try DemoPaper.write(to: original)
    let bytes = try Data(contentsOf: original)
    var block = TextBlock(sourcePage: 0, text: "Original page")
    block.preservesSourcePage = true
    let paper = Paper(
        title: "Retained figure", digest: "fixture", originalPath: "original.pdf", pageCount: 2,
        blocks: [block], warnings: [], canReflow: true)
    let artifact = try await HTMLReadingStore().append(
        [BilingualBlock(block: block, translation: nil)], to: nil, paper: paper, root: root)
    #expect(artifact.assets.count == 1)
    #expect(artifact.assets[0].hasSuffix(".png"))
    let html = try String(contentsOf: root.appendingPathComponent(artifact.relativePath), encoding: .utf8)
    #expect(html.contains("保留原版图表与公式"))
    #expect(artifact.sections[0].sourcePage == 0)
    #expect(try Data(contentsOf: original) == bytes)
}

@Test(arguments: [0, 90, 180, 270]) @MainActor
func htmlRetainedPageHonorsCropAndRotation(rotation: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = root.appendingPathComponent("original.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 500, height: 700)
    let context = try #require(CGContext(original as CFURL, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    for (color, rect) in [
        (CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGRect(x: 110, y: 210, width: 40, height: 40)),
        (CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGRect(x: 250, y: 210, width: 40, height: 40)),
        (CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGRect(x: 110, y: 450, width: 40, height: 40)),
        (CGColor(red: 1, green: 0, blue: 1, alpha: 1), CGRect(x: 250, y: 450, width: 40, height: 40)),
    ] {
        context.setFillColor(color)
        context.fill(rect)
    }
    context.endPDFPage()
    context.closePDF()
    let document = try #require(PDFDocument(url: original))
    let page = try #require(document.page(at: 0))
    page.setBounds(CGRect(x: 100, y: 200, width: 200, height: 300), for: .cropBox)
    page.rotation = rotation
    let annotation = PDFAnnotation(
        bounds: CGRect(x: 170, y: 310, width: 60, height: 60), forType: .square, withProperties: nil)
    annotation.color = .black
    page.addAnnotation(annotation)
    #expect(document.write(to: original))
    var block = TextBlock(sourcePage: 0, text: "Colored corner markers")
    block.preservesSourcePage = true
    let paper = Paper(
        title: "Crop and rotation", digest: "fixture", originalPath: "original.pdf", pageCount: 1,
        blocks: [block], warnings: [], canReflow: true)
    let artifact = try await HTMLReadingStore().append(
        [BilingualBlock(block: block, translation: nil)], to: nil, paper: paper, root: root)
    let source = try #require(CGImageSourceCreateWithURL(root.appendingPathComponent(artifact.assets[0]) as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(Double(image.width) / Double(image.height) == (rotation % 180 == 0 ? 2.0 / 3 : 3.0 / 2))
    let raster = try #require(
        CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    raster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try #require(raster.data).assumingMemoryBound(to: UInt8.self)
    var counts: [String: Int] = [:]
    for offset in stride(from: 0, to: image.width * image.height * 4, by: 4) {
        let r = bytes[offset]
        let g = bytes[offset + 1]
        let b = bytes[offset + 2]
        // PDFKit applies color management; identify channels without requiring raw RGB equality.
        if r > 220 && g < 85 && b < 85 { counts["red", default: 0] += 1 }
        if r < 85 && g > 220 && b < 85 { counts["green", default: 0] += 1 }
        if r < 85 && g < 85 && b > 220 { counts["blue", default: 0] += 1 }
        if r > 220 && g < 85 && b > 220 { counts["magenta", default: 0] += 1 }
        if r < 30 && g < 30 && b < 30 { counts["annotation", default: 0] += 1 }
    }
    for color in ["red", "green", "blue", "magenta"] { #expect((counts[color] ?? 0) >= 6_300) }
    #expect((counts["annotation"] ?? 0) > 400)
}
