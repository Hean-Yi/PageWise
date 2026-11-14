import CoreGraphics
import Foundation
import PDFKit

/// A bounded grayscale analysis image. Coordinates remain in the original PDF page space.
struct PDFFigurePixels {
    let pageBounds: CGRect
    let width: Int
    let height: Int
    let scale: CGFloat
    let pixels: [UInt8]
    let threshold: UInt8

    init?(page: PDFPage) {
        let bounds = page.bounds(for: .cropBox)
        guard page.rotation % 360 == 0, let reference = page.pageRef,
            bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite
        else { return nil }
        let scale = min(2, 1_600 / max(bounds.width, bounds.height))
        let width = Int(ceil(bounds.width * scale))
        let height = Int(ceil(bounds.height * scale))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Make bitmap row zero correspond to the PDF crop-box minimum Y.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.drawPDFPage(reference)
        guard let memory = context.data else { return nil }
        let pixels = Array(
            UnsafeBufferPointer(start: memory.assumingMemoryBound(to: UInt8.self), count: width * height))
        let border = (0..<width).map { pixels[$0] } + (0..<width).map { pixels[(height - 1) * width + $0] }
        let background = border.sorted()[border.count / 2]
        guard background >= 180 else { return nil }
        self.pageBounds = bounds
        self.width = width
        self.height = height
        self.scale = scale
        self.pixels = pixels
        self.threshold = background - 12
    }

    func pixelRect(_ rect: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        (
            max(0, min(width, Int(floor((rect.minX - pageBounds.minX) * scale)))),
            max(0, min(height, Int(floor((rect.minY - pageBounds.minY) * scale)))),
            max(0, min(width, Int(ceil((rect.maxX - pageBounds.minX) * scale)))),
            max(0, min(height, Int(ceil((rect.maxY - pageBounds.minY) * scale))))
        )
    }

    func inkBounds(in rect: CGRect) -> CGRect? {
        let p = pixelRect(rect)
        guard p.x0 < p.x1, p.y0 < p.y1 else { return nil }
        var minX = p.x1
        var minY = p.y1
        var maxX = p.x0 - 1
        var maxY = p.y0 - 1
        for y in p.y0..<p.y1 {
            for x in p.x0..<p.x1 where pixels[y * width + x] < threshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return pageRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func graphicComponents(excluding text: [CGRect]) throws -> [CGRect] {
        var masked = pixels
        for rect in text {
            let p = pixelRect(rect.insetBy(dx: -1.5, dy: -1.5))
            guard p.x0 < p.x1, p.y0 < p.y1 else { continue }
            for y in p.y0..<p.y1 { for x in p.x0..<p.x1 { masked[y * width + x] = 255 } }
        }
        let cell = max(2, Int(ceil(4 * scale)))
        let columns = (width + cell - 1) / cell
        let rows = (height + cell - 1) / cell
        var occupied = Array(repeating: false, count: columns * rows)
        for y in 0..<rows {
            try Task.checkCancellation()
            for x in 0..<columns {
                var ink = 0
                for py in (y * cell)..<min(height, (y + 1) * cell) {
                    for px in (x * cell)..<min(width, (x + 1) * cell) where masked[py * width + px] < threshold {
                        ink += 1
                    }
                }
                occupied[y * columns + x] = ink >= 2
            }
        }
        var result: [CGRect] = []
        for origin in occupied.indices where occupied[origin] {
            try Task.checkCancellation()
            var queue = [origin]
            var offset = 0
            occupied[origin] = false
            var minX = origin % columns
            var maxX = minX
            var minY = origin / columns
            var maxY = minY
            while offset < queue.count {
                let point = queue[offset]
                offset += 1
                let x = point % columns
                let y = point / columns
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                for ny in max(0, y - 1)...min(rows - 1, y + 1) {
                    for nx in max(0, x - 1)...min(columns - 1, x + 1) where occupied[ny * columns + nx] {
                        let next = ny * columns + nx
                        occupied[next] = false
                        queue.append(next)
                    }
                }
            }
            guard queue.count >= 3 else { continue }
            let rect = pageRect(
                x: minX * cell, y: minY * cell, width: (maxX - minX + 1) * cell, height: (maxY - minY + 1) * cell)
            if max(rect.width, rect.height) >= 16 { result.append(rect.intersection(pageBounds)) }
        }
        return result
    }

    private func pageRect(x: Int, y: Int, width: Int, height: Int) -> CGRect {
        CGRect(
            x: pageBounds.minX + CGFloat(x) / scale, y: pageBounds.minY + CGFloat(y) / scale,
            width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    }
}
