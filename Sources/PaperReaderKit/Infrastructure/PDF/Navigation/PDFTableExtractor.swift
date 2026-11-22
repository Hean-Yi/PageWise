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
        let requiresSourceInk: Bool
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
        guard (2...160).contains(lines.count), let image = PDFTableBitmap(page: page, bounds: bounds) else {
            return nil
        }
        let matrix = lines.map(cells)
        let layout: Layout
        if let grid = image.closedGrid(containing: words.map(\.bounds)) {
            guard let verified = gridLayout(grid, words: words, image: image) else { return nil }
            layout = verified
        } else {
            if columnsAgree(in: matrix) {
                // For semantic colors, retain the publisher's visible glyphs and attach the same
                // selectable matrix used for ruled tables. No inferred color is copied to other cells.
                let source = words.contains(where: \.requiresSourceInk) ? matrix.map { $0.map(\.bounds) } : []
                layout = Layout(flatHeader: matrix[0], body: Array(matrix.dropFirst()), sourceBounds: source)
            } else if let grouped = groupedLayout(matrix, on: page, in: bounds) {
                layout = grouped
            } else {
                return nil
            }
            guard containsOnlyTextAndRules(image: image, words: words, groupRules: layout.groupRules) else {
                return nil
            }
        }
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

    /// Explicit cell borders allow empty values and a single data row without inferring a missing column.
    private static func gridLayout(_ grid: PDFClosedTableGrid, words: [Word], image: PDFTableBitmap) -> Layout? {
        let nRows = grid.rows.count - 1
        let nCols = grid.columns.count - 1
        var slots = Array(repeating: Array(repeating: [Word](), count: nCols), count: nRows)
        for word in words {
            guard !Task.isCancelled,
                let column = (0..<nCols).first(where: {
                    grid.columns[$0] < word.bounds.minX && word.bounds.maxX < grid.columns[$0 + 1]
                }),
                let row = (0..<nRows).first(where: {
                    grid.rows[$0] > word.bounds.maxY && word.bounds.minY > grid.rows[$0 + 1]
                })
            else { return nil }
            slots[row][column].append(word)
        }
        var matrix: [[Cell]] = []
        for (row, line) in slots.enumerated() {
            var result: [Cell] = []
            for (column, slot) in line.enumerated() {
                if let first = slot.first {
                    guard
                        slot.allSatisfy({
                            abs($0.bounds.midY - first.bounds.midY) <= min($0.bounds.height, first.bounds.height) * 0.32
                        })
                    else { return nil }
                    let parts = cells(in: slot)
                    guard parts.count == 1, let cell = parts.first else { return nil }
                    result.append(cell)
                } else {
                    result.append(Cell(text: "", bounds: grid.cell(row: row, column: column), runs: []))
                }
            }
            guard result.contains(where: { !$0.text.isEmpty }) else { return nil }
            matrix.append(result)
        }
        guard let header = matrix.first, header.allSatisfy({ !$0.text.isEmpty }),
            header.contains(where: { $0.text.contains(where: \.isLetter) })
        else { return nil }
        for rule in grid.rules { image.mask(rule.insetBy(dx: -0.5, dy: -0.5)) }
        for word in words { image.mask(word.bounds.insetBy(dx: -0.8, dy: -0.8)) }
        guard (0..<image.height).allSatisfy({ image.inkRuns(at: $0).isEmpty }) else { return nil }
        return Layout(
            flatHeader: header, body: Array(matrix.dropFirst()), sourceBounds: matrix.map { $0.map(\.bounds) })
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

    /// Confirm two printed header tiers against both the body columns and the painted group underlines.
    /// A standalone stub may be on either printed baseline, between them, or absent.
    private static func groupedLayout(_ matrix: [[Cell]], on page: PDFPage, in bounds: CGRect) -> Layout? {
        guard matrix.count >= 4, var groups = matrix.first, !groups.isEmpty else { return nil }
        var leafRow = 1
        var stub: Cell?
        if matrix.count >= 5, matrix[1].count == 1, let between = matrix[1].first,
            between.bounds.maxX < groups[0].bounds.minX,
            let next = matrix[2].first, between.bounds.maxX < next.bounds.minX
        {
            stub = between
            leafRow = 2
        }
        var leaves = matrix[leafRow]
        let body = Array(matrix.dropFirst(leafRow + 1))
        guard let width = body.first?.count, (2...20).contains(width), leaves.count >= 2 else { return nil }
        if stub == nil {
            if leaves.count == width - 1, groups.count > 1, groups[0].bounds.maxX < leaves[0].bounds.minX {
                stub = groups.removeFirst()
            } else if leaves.count == width, groups[0].bounds.minX > leaves[0].bounds.maxX,
                let firstBody = body.first?.first, firstBody.bounds.maxX < groups[0].bounds.minX,
                // The first group may instead legitimately span column zero: a painted rule decides.
                verifiedGroupRules(top: groups, leaves: leaves, on: page, in: bounds) == nil
            {
                stub = leaves.removeFirst()
            }
        }
        if var label = stub, label.runs.allSatisfy({ $0.baseline == .subscript || $0.text.allSatisfy(\.isWhitespace) })
        {
            // PDFKit can encode the vertical alignment of a whole stub as a baseline offset.
            label.runs = label.runs.map { Run(text: $0.text, bold: $0.bold, italic: $0.italic) }
            label.text = label.runs.map(\.text).joined()
            stub = label
        }
        let stubs = stub.map { [$0] } ?? []
        let flatHeader = stubs + leaves
        guard flatHeader.count == width, columnsAgree(in: [flatHeader] + body),
            let rules = verifiedGroupRules(top: groups, leaves: leaves, on: page, in: bounds)
        else { return nil }
        var upper: [PDFReadingTable.HeaderCell] = stubs.map {
            .init(text: $0.text, column: 0, rowSpan: 2, runs: $0.runs)
        }
        var column = stubs.count
        for (label, rule) in zip(groups, rules) {
            let memberCount = leaves.filter { rule.minX <= $0.bounds.midX && $0.bounds.midX <= rule.maxX }.count
            upper.append(.init(text: label.text, column: column, columnSpan: memberCount, runs: label.runs))
            column += memberCount
        }
        let lower = leaves.enumerated().map { index, label in
            PDFReadingTable.HeaderCell(text: label.text, column: index + stubs.count, runs: label.runs)
        }
        return Layout(
            flatHeader: flatHeader, body: body, headerRows: [upper, lower],
            sourceBounds: ([stubs + groups, leaves] + body).map { $0.map(\.bounds) }, groupRules: rules)
    }

    private static func verifiedGroupRules(top: [Cell], leaves: [Cell], on page: PDFPage, in bounds: CGRect)
        -> [CGRect]?
    {
        guard let upper = top.first, let lower = leaves.first else { return nil }
        let gap = upper.bounds.midY - lower.bounds.midY
        guard gap > 0 else { return nil }
        // Rendering only the inter-header strip keeps text in the adjacent table/body out of this measurement.
        let band = CGRect(x: bounds.minX, y: lower.bounds.midY + gap * 0.25, width: bounds.width, height: gap * 0.65)
        guard let image = PDFTableBitmap(page: page, bounds: band) else { return nil }
        for y in 0..<image.height {
            let runs = image.inkRuns(at: y).map { image.rectangle(for: $0, row: y) }.filter { run in
                leaves.filter { run.minX < $0.bounds.midX && $0.bounds.midX < run.maxX }.count >= 2
            }
            guard runs.count == top.count else { continue }
            var covered: [Int] = []
            for (label, run) in zip(top, runs) {
                // Inset underlines can stop short of leaf text edges. The group title must fit the
                // rule and the majority of each member's printed heading must lie in its interval.
                let members = leaves.indices.filter {
                    run.minX < leaves[$0].bounds.midX && leaves[$0].bounds.midX < run.maxX
                }
                guard run.minX <= label.bounds.minX + 1, run.maxX >= label.bounds.maxX - 1,
                    members.allSatisfy({
                        let box = leaves[$0].bounds
                        return min(run.maxX, box.maxX) - max(run.minX, box.minX) >= box.width * 0.6
                    })
                else { break }
                covered.append(contentsOf: members)
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
        var requiresSourceInk = false
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
                    .components, rgb.count == 4
            {
                guard rgb[3] > 0.05 else {
                    valid = false
                    stop.pointee = true
                    return
                }
                let channels = rgb.prefix(3)
                if channels.max()! - channels.min()! > 0.08 || channels.min()! > 0.25 || rgb[3] < 0.9 {
                    requiresSourceInk = true
                }
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
        return Word(text: value, bounds: box, runs: runs, sourceRange: range, requiresSourceInk: requiresSourceInk)
    }

    /// Mask the actual word bounds. Remaining paint must be thin horizontal rules, so icon-only cells,
    /// diagrams and heat maps cannot disappear when we switch from the published crop to selectable text.
    private static func containsOnlyTextAndRules(image: PDFTableBitmap, words: [Word], groupRules: [CGRect])
        -> Bool
    {
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
}
