import CoreText
import Foundation
import PDFKit

#if os(macOS)
    private typealias TableTextColor = NSColor
#else
    private typealias TableTextColor = UIColor
#endif

/// Recover a rectangular text table from a previously verified table-body crop.
enum PDFTableExtractor {
    private typealias Run = PDFReadingTable.Run

    private struct Word {
        let text: String
        let bounds: CGRect
        let runs: [Run]
        let sourceRange: NSRange
    }

    private struct Cell {
        var text: String
        var bounds: CGRect
        var runs: [Run]
    }

    private static let token = try! NSRegularExpression(pattern: #"\S+"#)
    private static let superscripts = Dictionary(uniqueKeysWithValues: zip("0123456789−-+()", "⁰¹²³⁴⁵⁶⁷⁸⁹⁻⁻⁺⁽⁾"))

    static func extract(on page: PDFPage, in bounds: CGRect) -> PDFReadingTable? {
        guard page.rotation % 360 == 0, !bounds.isEmpty, !bounds.isInfinite,
            [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
            page.numberOfCharacters <= 70_000, let text = page.attributedString,
            text.length == page.numberOfCharacters, let selection = page.selection(for: bounds)
        else { return nil }
        let source = text.string as NSString
        var words: [Word] = []
        let ranges = selection.numberOfTextRanges(on: page)
        guard (1...1_000).contains(ranges) else { return nil }
        for i in 0..<ranges {
            let range = selection.range(at: i, on: page)
            guard !Task.isCancelled, range.location != NSNotFound, NSMaxRange(range) <= text.length else { return nil }
            for match in token.matches(in: text.string, range: range) {
                let raw = source.substring(with: match.range)
                guard words.count < 2_000, let unit = page.selection(for: match.range), unit.string == raw,
                    !raw.unicodeScalars.contains(where: {
                        $0 == "\u{fffd}" || $0.properties.generalCategory == .privateUse
                    })
                else { return nil }
                let box = unit.bounds(for: page)
                guard box.width > 0, box.height > 0, bounds.insetBy(dx: -1, dy: -1).contains(box),
                    let word = word(in: match.range, text: text, box: box)
                else { return nil }
                words.append(word)
            }
        }
        let sorted = words.sorted { $0.bounds.midY > $1.bounds.midY }
        var lines: [[Word]] = []
        for word in sorted {
            if let first = lines.last?.first,
                abs(first.bounds.midY - word.bounds.midY) <= min(first.bounds.height, word.bounds.height) * 0.32
            {
                lines[lines.count - 1].append(word)
            } else {
                lines.append([word])
            }
        }
        guard (3...160).contains(lines.count) else { return nil }
        let matrix = lines.map(cells)
        let layout: Layout
        if columnsAgree(in: matrix) {
            layout = Layout(flatHeader: matrix[0], body: Array(matrix.dropFirst()))
        } else if let grouped = groupedLayout(matrix, on: page, in: bounds) {
            layout = grouped
        } else {
            return nil
        }
        guard containsOnlyTextAndRules(page: page, bounds: bounds, words: words, groupRules: layout.groupRules)
        else { return nil }
        var styles: [PDFReadingTable.StyledCell] = []
        // In both layouts the first data row has style index 1.
        for (row, cells) in ([layout.flatHeader] + layout.body).enumerated() {
            for (column, cell) in cells.enumerated()
            where cell.runs.contains(where: { $0.baseline != .normal || $0.bold || $0.italic }) {
                styles.append(.init(row: row, column: column, runs: cell.runs))
            }
        }
        return PDFReadingTable(
            header: layout.flatHeader.map(\.text), rows: layout.body.map { $0.map(\.text) }, styledCells: styles,
            headerRows: layout.headerRows, sourceCellBounds: layout.sourceBounds)
    }

    private struct Layout {
        let flatHeader: [Cell]
        let body: [[Cell]]
        var headerRows: [[PDFReadingTable.HeaderCell]] = []
        var sourceBounds: [[CGRect]] = []
        var groupRules: [CGRect] = []
    }

    private static func columnsAgree(in matrix: [[Cell]]) -> Bool {
        guard let header = matrix.first, (2...20).contains(header.count), matrix.count >= 3,
            matrix.allSatisfy({ $0.count == header.count })
        else { return false }
        var rightEdge = -CGFloat.infinity
        for col in header.indices {
            let boxes = matrix.map { $0[col].bounds }
            guard let left = boxes.map(\.minX).min(), left > rightEdge,
                let nextEdge = boxes.map(\.maxX).max()
            else { return false }
            let body = boxes.dropFirst()
            let tolerance = max(2, header[col].bounds.height * 0.55)
            guard
                [\CGRect.minX, \.midX, \.maxX].contains(where: { edge in
                    let positions = body.map { $0[keyPath: edge] }
                    return positions.max()! - positions.min()! <= tolerance
                })
            else { return false }
            rightEdge = nextEdge
        }
        return true
    }

    /// Accept exactly two header tiers with an independently drawn underline for every column group.
    /// The left row header spans both tiers. All data rows must be complete and regularly aligned.
    private static func groupedLayout(_ matrix: [[Cell]], on page: PDFPage, in bounds: CGRect) -> Layout? {
        guard matrix.count >= 4, let top = matrix.first, top.count >= 2 else { return nil }
        let leaves = matrix[1]
        let body = Array(matrix.dropFirst(2))
        guard leaves.count >= 2 * (top.count - 1), leaves.count < 20, var leading = top.first,
            // PDFKit folds the vertically centered title into the upper baseline and offsets the entire title.
            leading.runs.allSatisfy({ $0.baseline == .subscript }),
            leading.bounds.maxX < (leaves.first?.bounds.minX ?? -.infinity)
        else { return nil }
        leading.runs = leading.runs.map { Run(text: $0.text, bold: $0.bold, italic: $0.italic) }
        leading.text = leading.runs.map(\.text).joined()
        let flatHeader = [leading] + leaves
        guard columnsAgree(in: [flatHeader] + body),
            let rules = verifiedGroupRules(top: Array(top.dropFirst()), leaves: leaves, on: page, in: bounds)
        else { return nil }
        var upper: [PDFReadingTable.HeaderCell] = [
            .init(text: leading.text, column: 0, rowSpan: 2, runs: leading.runs)
        ]
        var column = 1
        for (label, rule) in zip(top.dropFirst(), rules) {
            let memberCount = leaves.filter { rule.minX <= $0.bounds.midX && $0.bounds.midX <= rule.maxX }.count
            upper.append(.init(text: label.text, column: column, columnSpan: memberCount, runs: label.runs))
            column += memberCount
        }
        let lower = leaves.enumerated().map { index, label in
            PDFReadingTable.HeaderCell(text: label.text, column: index + 1, runs: label.runs)
        }
        return Layout(
            flatHeader: flatHeader, body: body, headerRows: [upper, lower],
            sourceBounds: matrix.map { $0.map(\.bounds) },
            groupRules: rules)
    }

    private static func verifiedGroupRules(top: [Cell], leaves: [Cell], on page: PDFPage, in bounds: CGRect)
        -> [CGRect]?
    {
        guard let upper = top.first, let lower = leaves.first else { return nil }
        let gap = upper.bounds.midY - lower.bounds.midY
        guard gap > 0 else { return nil }
        // Rendering only the inter-header strip keeps text in the adjacent table/body out of this measurement.
        let band = CGRect(x: bounds.minX, y: lower.bounds.midY + gap * 0.25, width: bounds.width, height: gap * 0.65)
        guard let image = TableBitmap(page: page, bounds: band) else { return nil }
        for y in 0..<image.height {
            let runs = image.inkRuns(at: y).map { image.rectangle(for: $0, row: y) }.filter { run in
                leaves.filter { run.minX < $0.bounds.midX && $0.bounds.midX < run.maxX }.count >= 2
            }
            guard runs.count == top.count else { continue }
            var covered: [Int] = []
            for (label, run) in zip(top, runs) {
                // A rule centered under the printed title must span only the columns belonging to it.
                guard abs(label.bounds.midX - run.midX) < max(2, label.bounds.height * 0.6),
                    run.minX <= label.bounds.minX + 1, run.maxX >= label.bounds.maxX - 1
                else { break }
                covered.append(
                    contentsOf: leaves.indices.filter {
                        run.minX < leaves[$0].bounds.midX && leaves[$0].bounds.midX < run.maxX
                    })
            }
            if covered == Array(leaves.indices) { return runs }
        }
        return nil
    }

    private static func cells(in row: [Word]) -> [Cell] {
        var cells: [Cell] = []
        var previous: Word?
        for word in row.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            let gap = previous.map { word.bounds.minX - $0.bounds.maxX } ?? .infinity
            guard gap >= -max(1, word.bounds.height * 0.12) else { return [] }
            if let previous, gap < max(4.5, word.bounds.height * 0.68) {
                // PDFKit sometimes inserts a blank after a subscript, even before a closing parenthesis.
                let scriptPadding = previous.runs.last?.baseline != .normal && gap < 1 && word.text.first == ")"
                let separated = NSMaxRange(previous.sourceRange) != word.sourceRange.location && !scriptPadding
                if separated { cells[cells.count - 1].runs.append(Run(text: " ")) }
                cells[cells.count - 1].runs.append(contentsOf: word.runs)
                cells[cells.count - 1].text += (separated ? " " : "") + word.text
                cells[cells.count - 1].bounds = cells[cells.count - 1].bounds.union(word.bounds)
            } else {
                cells.append(Cell(text: word.text, bounds: word.bounds, runs: word.runs))
            }
            previous = word
        }
        return cells
    }

    private static func word(in range: NSRange, text: NSAttributedString, box: CGRect) -> Word? {
        var runs: [Run] = []
        var valid = true
        let source = text.string as NSString
        text.enumerateAttributes(in: range) { attributes, span, stop in
            let raw = source.substring(with: span)
            let key = NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)
            let offset = (attributes[key] as? NSNumber)?.doubleValue ?? 0
            guard abs(offset) < box.height else {
                valid = false
                stop.pointee = true
                return
            }
            let baseline: PDFReadingTable.Baseline =
                offset > 0.4 ? .superscript : (offset < -0.4 ? .subscript : .normal)
            if let color = attributes[.foregroundColor] as? TableTextColor,
                let rgb = color.cgColor.converted(
                    to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric, options: nil)?
                    .components,
                rgb.count == 4, rgb.prefix(3).max()! - rgb.prefix(3).min()! > 0.08
            {
                valid = false
                stop.pointee = true
                return
            }
            var traits: CTFontSymbolicTraits = []
            if let font = attributes[NSAttributedString.Key(kCTFontAttributeName as String)],
                CFGetTypeID(font as CFTypeRef) == CTFontGetTypeID()
            {
                traits = CTFontGetSymbolicTraits(font as! CTFont)
            }
            runs.append(
                Run(
                    text: raw, baseline: baseline, bold: traits.contains(.traitBold),
                    italic: traits.contains(.traitItalic)))
        }
        guard valid else { return nil }
        var value = ""
        var index = runs.startIndex
        while index < runs.endIndex {
            let baseline = runs[index].baseline
            let start = index
            while index < runs.endIndex, runs[index].baseline == baseline { index += 1 }
            let raw = runs[start..<index].map(\.text).joined()
            switch baseline {
            case .normal: value += raw
            case .subscript: value += "_{" + raw + "}"
            case .superscript where raw.allSatisfy({ "†‡*§¶".contains($0) }): value += raw
            case .superscript:
                value +=
                    raw.allSatisfy { superscripts[$0] != nil }
                    ? String(raw.compactMap { superscripts[$0] }) : "^{" + raw + "}"
            }
        }
        return Word(text: value, bounds: box, runs: runs, sourceRange: range)
    }

    /// Mask the actual word bounds. Remaining paint must be thin horizontal rules, so icon-only cells,
    /// diagrams and heat maps cannot disappear when we switch from the published crop to selectable text.
    private static func containsOnlyTextAndRules(page: PDFPage, bounds: CGRect, words: [Word], groupRules: [CGRect])
        -> Bool
    {
        guard let image = TableBitmap(page: page, bounds: bounds) else { return false }
        // Mask group underlines only after their endpoints and full column coverage have been validated.
        for rule in groupRules { image.mask(rule.insetBy(dx: -0.5, dy: -1)) }
        if !groupRules.isEmpty {
            // A group separator is a long vertical rule in a gutter between text columns.
            image.maskVerticalRules(inGuttersOf: words.map(\.bounds), between: groupRules)
        }
        for word in words { image.mask(word.bounds.insetBy(dx: -0.8, dy: -0.8)) }
        var thickness = 0
        for y in 0..<image.height {
            let ink = image.inkRuns(at: y).reduce(0) { $0 + $1.count }
            if ink == 0 {
                thickness = 0
            } else {
                guard ink >= Int(CGFloat(image.width) * 0.75) else { return false }
                thickness += 1
                guard CGFloat(thickness) <= ceil(image.scale * 2.5) else { return false }
            }
        }
        return true
    }

    /// Axis-aligned rays in page coordinates, where positive y increases towards the top of the page.
    private struct TableBitmap {
        let bounds: CGRect
        let scale: CGFloat
        let width: Int
        let height: Int
        let bitmap: CGContext
        let pixels: UnsafeMutablePointer<UInt8>

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
}
