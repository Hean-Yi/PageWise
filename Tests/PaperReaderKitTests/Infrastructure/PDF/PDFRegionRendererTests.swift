import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import PaperReaderKit

struct PDFRegionRendererTests {
    private let region = CGRect(x: 80, y: 75, width: 40, height: 20)

    @Test(arguments: [0, 90, 180, 270])
    func cropUsesPageCoordinatesAndDisplaysInReadingOrientation(rotation: Int) throws {
        let document = try fixture()
        let page = try #require(document.page(at: 0))
        page.rotation = rotation
        let png = try #require(PDFRegionRenderer.png(page: page, bounds: region))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == (rotation.isMultiple(of: 180) ? 160 : 80))
        #expect(image.height == (rotation.isMultiple(of: 180) ? 80 : 160))

        // Read the four quadrants clockwise from the top left in the displayed PNG.
        let colors = try [(0.25, 0.25), (0.75, 0.25), (0.75, 0.75), (0.25, 0.75)].map { x, y in
            try rgb(image, x: x, y: y)
        }
        let expected = [0xff0000, 0xffffff, 0x0000ff, 0xffffff]
        for (corner, color) in expected.enumerated() {
            #expect(colors[(corner + rotation / 90) % 4] == color)
        }
    }

    @Test func fallsBackForInvalidOrPartlyHiddenRegions() throws {
        let document = try fixture()
        let page = try #require(document.page(at: 0))
        for rect: CGRect in [
            .null, .infinite, .zero, CGRect(x: CGFloat.nan, y: 40, width: 5, height: 5),
            CGRect(x: 50, y: 75, width: 40, height: 20),
        ] {
            #expect(PDFRegionRenderer.png(page: page, bounds: rect) == nil)
        }
    }

    @Test func limitsRasterMemoryForLargeAndElongatedCrops() throws {
        let document = try fixture(crop: CGRect(x: 45, y: 35, width: 2000, height: 2000))
        let page = try #require(document.page(at: 0))
        for (bounds, maxWidth) in [
            (page.bounds(for: .cropBox), 1448), (CGRect(x: 50, y: 50, width: 1500, height: 20), 2048),
        ] {
            let png = try #require(PDFRegionRenderer.png(page: page, bounds: bounds))
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == maxWidth)
            #expect(image.width * image.height <= 2_097_152)
        }
    }

    private func fixture(crop: CGRect = CGRect(x: 60, y: 40, width: 160, height: 120)) throws -> PDFDocument {
        var crop = crop
        var media = crop.insetBy(dx: -15, dy: -25)
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        let info = [kCGPDFContextCropBox as String: NSData(bytes: &crop, length: MemoryLayout<CGRect>.size)]
        context.beginPDFPage(info as CFDictionary)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 80, y: 85, width: 20, height: 10))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 100, y: 75, width: 20, height: 10))
        context.endPDFPage()
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    private func rgb(_ image: CGImage, x: Double, y: Double) throws -> Int {
        let rect = CGRect(x: floor(Double(image.width) * x), y: floor(Double(image.height) * y), width: 1, height: 1)
        let sample = try #require(image.cropping(to: rect))
        let context = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Int(bytes[0]) << 16 | Int(bytes[1]) << 8 | Int(bytes[2])
    }
}
