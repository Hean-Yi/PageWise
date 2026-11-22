import CoreGraphics
import Foundation
import PDFKit

/// A bounded grayscale copy used only to measure ink. Rows count upwards from the crop box's minimum Y.
struct PDFCaptionInk {
    let box: CGRect
    private let bitmap: CGContext
    private let scale: CGFloat

    init?(_ page: PDFPage) {
        let box = page.bounds(for: .cropBox)
        guard page.rotation % 360 == 0, let ref = page.pageRef, ref.rotationAngle % 360 == 0,
            [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
            box.width >= 40, box.height >= 40
        else { return nil }
        let scale = min(2, 1_500 / max(box.width, box.height))
        let w = Int(ceil(box.width * scale))
        let h = Int(ceil(box.height * scale))
        guard
            let bitmap = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
            bitmap.data != nil
        else { return nil }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bitmap.translateBy(x: 0, y: CGFloat(h))
        bitmap.scaleBy(x: scale, y: -scale)
        bitmap.translateBy(x: -box.minX, y: -box.minY)
        bitmap.drawPDFPage(ref)
        self.bitmap = bitmap
        self.box = box
        self.scale = scale
    }

    struct Strip {
        var bounds: CGRect
        var longestStroke: CGFloat
        var drawnRows: Int
    }

    /// Separate continuous runs of painted rows. Preserve the full horizontal extent of each row,
    /// including detached axis ticks, table cells, and light backgrounds.
    func strips(in region: CGRect) throws -> [Strip] {
        let region = region.intersection(box)
        guard !region.isEmpty, let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let x0 = max(0, Int(ceil((region.minX - box.minX) * scale)))
        let x1 = min(bitmap.width, Int(floor((region.maxX - box.minX) * scale)))
        let y0 = max(0, Int(ceil((region.minY - box.minY) * scale)))
        let y1 = min(bitmap.height, Int(floor((region.maxY - box.minY) * scale)))
        guard x0 < x1, y0 < y1 else { return [] }
        var result = [Strip]()
        var lastRow = -2
        for y in y0..<y1 {
            try Task.checkCancellation()
            let row = pixels.advanced(by: y * bitmap.bytesPerRow)
            var left = x1
            var right = x0 - 1
            var longest = 0
            var run = 0
            for x in x0..<x1 {
                if row[x] < 244 {
                    left = min(left, x)
                    right = x
                    run += 1
                    longest = max(longest, run)
                } else {
                    run = 0
                }
            }
            guard right >= left else { continue }
            let bounds = CGRect(
                x: box.minX + CGFloat(left) / scale, y: box.minY + CGFloat(y) / scale,
                width: CGFloat(right - left + 1) / scale, height: 1 / scale)
            let stroke = CGFloat(longest) / scale
            if y == lastRow + 1 {
                let i = result.count - 1
                result[i].bounds = result[i].bounds.union(bounds)
                result[i].longestStroke = max(result[i].longestStroke, stroke)
                if stroke >= 16 { result[i].drawnRows += 1 }
            } else {
                result.append(Strip(bounds: bounds, longestStroke: stroke, drawnRows: stroke >= 16 ? 1 : 0))
            }
            lastRow = y
        }
        return result
    }
}
