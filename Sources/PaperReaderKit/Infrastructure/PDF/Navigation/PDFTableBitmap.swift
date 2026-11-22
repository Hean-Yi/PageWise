import Foundation
import PDFKit

/// Axis-aligned rays in page coordinates, where positive y increases towards the top of the page.
struct PDFTableBitmap {
    private let bounds: CGRect
    let scale: CGFloat
    let width: Int
    let height: Int
    private let bitmap: CGContext
    private let pixels: UnsafeMutablePointer<UInt8>

    init?(page: PDFPage, bounds: CGRect) {
        guard let ref = page.pageRef else { return nil }
        self.bounds = bounds
        scale = min(2, 1_400 / max(bounds.width, bounds.height))
        width = Int(ceil(bounds.width * scale))
        height = Int(ceil(bounds.height * scale))
        guard width > 0, height > 0,
            let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
            let data = bitmap.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        self.bitmap = bitmap
        pixels = data
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.translateBy(x: -bounds.minX, y: -bounds.minY)
        bitmap.drawPDFPage(ref)
        bitmap.setFillColor(gray: 1, alpha: 1)
    }

    func mask(_ box: CGRect) { bitmap.fill(box) }

    func inkRuns(at row: Int) -> [Range<Int>] {
        let line = pixels.advanced(by: row * width)
        var result: [Range<Int>] = []
        var start: Int?
        for x in 0..<width {
            if line[x] < 238 {
                if start == nil { start = x }
            } else if let end = start {
                result.append(end..<x)
                start = nil
            }
        }
        if let start { result.append(start..<width) }
        return result
    }

    func rectangle(for range: Range<Int>, row: Int) -> CGRect {
        CGRect(
            x: bounds.minX + CGFloat(range.lowerBound) / scale, y: bounds.minY + CGFloat(height - row - 1) / scale,
            width: CGFloat(range.count) / scale, height: 1 / scale)
    }

    func maskVerticalRules(inGuttersOf boxes: [CGRect], between groupRules: [CGRect]) {
        // The table may have no vertical ink. Only mask a thin, long, genuinely painted
        // divider alongside a group (never an isolated footnote, symbol or diagram).
        let ruleStarts = groupRules.map(\.minX)
        let threshold = CGFloat(height) * 0.57
        var columns: [Int] = []
        for x in 0..<width {
            let point = bounds.minX + (CGFloat(x) + 0.5) / scale
            guard ruleStarts.contains(where: { point <= $0 && $0 - point < 8 }),
                boxes.allSatisfy({ point < $0.minX || point > $0.maxX })
            else { continue }
            var ink = 0
            for y in 0..<height where pixels[y * width + x] < 238 { ink += 1 }
            if CGFloat(ink) >= threshold { columns.append(x) }
        }
        for x in columns {
            let neighbors = columns.filter { abs($0 - x) <= Int(ceil(scale * 2)) }
            guard CGFloat(neighbors.count) <= ceil(scale * 1.5) else { continue }
            mask(
                CGRect(x: bounds.minX + CGFloat(x) / scale, y: bounds.minY, width: 1 / scale, height: bounds.height)
            )
        }
    }
}

/// Each interval is bounded by a continuous painted rule on all four sides.
struct PDFClosedTableGrid {
    let columns: [CGFloat]
    let rows: [CGFloat]  // Top to bottom, in PDF coordinates.
    let rules: [CGRect]

    func cell(row: Int, column: Int) -> CGRect {
        CGRect(
            x: columns[column], y: rows[row + 1], width: columns[column + 1] - columns[column],
            height: rows[row] - rows[row + 1])
    }
}

extension PDFTableBitmap {
    /// Inspect actual pixels across the matrix. A mostly complete rule cannot prove an empty cell.
    func closedGrid(containing words: [CGRect]) -> PDFClosedTableGrid? {
        guard let first = words.first else { return nil }
        let area = words.dropFirst().reduce(first) { $0.union($1) }
        let x0 = max(0, Int(floor((area.minX - bounds.minX) * scale)))
        let x1 = min(width - 1, Int(ceil((area.maxX - bounds.minX) * scale)))
        guard x1 > x0 else { return nil }

        let horizontal = (0..<height).compactMap { y -> (Int, Range<Int>)? in
            let line = pixels.advanced(by: y * width)
            guard line[x0] < 238, line[x1] < 238, line[(x0 + x1) / 2] < 238,
                let ink = inkRuns(at: y).first(where: { $0.contains(x0) && $0.contains(x1) })
            else { return nil }
            return (y, ink)
        }
        guard let firstRule = horizontal.first, let lastRule = horizontal.last,
            horizontal.allSatisfy({
                abs($0.1.lowerBound - firstRule.1.lowerBound) <= 2 && abs($0.1.upperBound - firstRule.1.upperBound) <= 2
            }), let yBands = thinBands(horizontal.map { $0.0 }), (3...161).contains(yBands.count)
        else { return nil }
        // Skip the antialiased outer edge of the horizontal rules when measuring their intersections.
        let top = yBands[0].upperBound - 1
        let bottom = yBands[yBands.count - 1].lowerBound
        guard top < bottom else { return nil }
        let vertical = (0..<width).filter { x in
            guard pixels[top * width + x] < 238, pixels[bottom * width + x] < 238,
                pixels[((top + bottom) / 2) * width + x] < 238
            else { return false }
            return (top...bottom).allSatisfy { pixels[$0 * width + x] < 238 }
        }
        guard let xBands = thinBands(vertical), (3...21).contains(xBands.count),
            let firstColumn = xBands.first, let lastColumn = xBands.last,
            abs(firstColumn.lowerBound - firstRule.1.lowerBound) <= 2,
            abs(lastColumn.upperBound - lastRule.1.upperBound) <= 2
        else { return nil }

        func pageX(_ x: CGFloat) -> CGFloat { bounds.minX + x / scale }
        func pageY(_ y: CGFloat) -> CGFloat { bounds.minY + (CGFloat(height) - y) / scale }
        func middle(_ band: Range<Int>) -> CGFloat { CGFloat(band.lowerBound + band.upperBound) / 2 }
        let columns = xBands.map { pageX(middle($0)) }
        let rows = yBands.map { pageY(middle($0)) }
        guard area.minX > columns[0], area.maxX < columns[columns.count - 1],
            area.maxY < rows[0], area.minY > rows[rows.count - 1]
        else { return nil }
        let xRange = firstColumn.lowerBound..<lastColumn.upperBound
        let yRange = firstRule.0..<(lastRule.0 + 1)
        func rect(_ x: Range<Int>, _ y: Range<Int>) -> CGRect {
            CGRect(
                x: pageX(CGFloat(x.lowerBound)), y: pageY(CGFloat(y.upperBound)),
                width: CGFloat(x.count) / scale, height: CGFloat(y.count) / scale)
        }
        return PDFClosedTableGrid(
            columns: columns, rows: rows,
            rules: xBands.map { rect($0, yRange) } + yBands.map { rect(xRange, $0) })
    }

    private func thinBands(_ positions: [Int]) -> [Range<Int>]? {
        var bands: [Range<Int>] = []
        for value in positions {
            if let last = bands.last, last.upperBound == value {
                guard CGFloat(last.count + 1) <= ceil(scale * 2.5) else { return nil }
                bands[bands.count - 1] = last.lowerBound..<(value + 1)
            } else {
                bands.append(value..<(value + 1))
            }
        }
        return bands
    }
}
