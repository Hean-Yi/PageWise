import Foundation
import PDFKit

struct PDFCaptionRegion {
    let label: String
    let captionBounds: CGRect
    let captionRange: NSRange
    let sourceBounds: CGRect?
}

/// Locate an illustration only when a numbered caption and the painted page independently agree.
enum PDFCaptionRegionDetector {
    private struct Line {
        let text: String
        let bounds: CGRect
        let range: NSRange
        var words: [Substring] { text.split(whereSeparator: \.isWhitespace) }
        var isProse: Bool {
            let words = words
            return words.count >= 5 && text.count >= 28
                && words.filter { $0.filter(\.isLetter).count >= 2 }.count * 4 >= words.count * 3
        }
    }

    private struct Marker {
        let label: String
        let range: NSRange
        let separator: String
        let title: String

        var looksLikeHeading: Bool {
            !separator.isEmpty || title.isEmpty || title.first?.isUppercase == true
                || title.localizedCaseInsensitiveCompare("(continued)") == .orderedSame
        }
    }

    private static let number = try! NSRegularExpression(
        pattern:
            #"^\s*(Figure|Fig\.?|Table|Tab\.?)\s*([A-Z]?[.]?\d+(?:\.\d+)*[a-z]?|[IVXLCDM]+)(?:\s*([.:|–—-])(?!\d)|(?=\s|$))"#,
        options: .caseInsensitive)

    private static func marker(in line: String) -> Marker? {
        let text = line as NSString
        guard let match = number.firstMatch(in: line, range: NSRange(location: 0, length: text.length))
        else { return nil }
        let kind = text.substring(with: match.range(at: 1)).lowercased().hasPrefix("tab") ? "表 " : "图 "
        let punctuation = match.range(at: 3)
        return Marker(
            label: kind + text.substring(with: match.range(at: 2)), range: match.range,
            separator: punctuation.location == NSNotFound ? "" : text.substring(with: punctuation),
            title: text.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A text-only hint may separate reading paragraphs. Publishing a crop also requires page geometry.
    static func captionLabel(in line: String) -> String? {
        guard let marker = marker(in: line), marker.looksLikeHeading else { return nil }
        return marker.label
    }

    static func regions(on page: PDFPage) throws -> [PDFCaptionRegion] {
        try Task.checkCancellation()
        let box = page.bounds(for: .cropBox)
        guard page.rotation % 360 == 0, page.numberOfCharacters > 0, page.numberOfCharacters <= 70_000,
            let source = page.string as NSString?, source.length == page.numberOfCharacters,
            let selected = page.selection(for: NSRange(location: 0, length: source.length))
        else { return [] }
        let selections = selected.selectionsByLine()
        guard selections.count <= 2_000 else { return [] }
        var lines = [Line]()
        var marginStamps: [CGRect] = []
        for selection in selections {
            try Task.checkCancellation()
            guard selection.numberOfTextRanges(on: page) == 1 else { continue }
            let range = selection.range(at: 0, on: page)
            let bounds = selection.bounds(for: page)
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= source.length,
                bounds.width > 0, bounds.height > 0,
                box.contains(CGPoint(x: bounds.midX, y: bounds.midY))
            else { continue }
            let text = source.substring(with: range)
            guard bounds.height < max(24, bounds.width * 1.5) else {
                let margin = min(bounds.midX - box.minX, box.maxX - bounds.midX)
                if bounds.height > 3 * bounds.width, margin < box.width * 0.09,
                    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("arxiv:")
                {
                    marginStamps.append(bounds)
                }
                continue
            }
            lines.append(Line(text: text, bounds: bounds, range: range))
        }

        let anchors = lines.compactMap { line -> (Line, Marker)? in
            guard var prefix = marker(in: line.text), prefix.looksLikeHeading else { return nil }
            // A PDF text range can start in the middle of a visual line, including at a prose reference.
            guard
                !lines.contains(where: {
                    $0.range != line.range && abs($0.bounds.midY - line.bounds.midY) < line.bounds.height * 0.35
                        && $0.bounds.maxX <= line.bounds.minX + 1
                        && line.bounds.minX - $0.bounds.maxX < line.bounds.height * 0.9
                })
            else { return nil }
            // A line-wrapped reference can have exactly the punctuation of a caption.
            if prefix.separator.isEmpty || prefix.separator == "." {
                guard
                    !lines.contains(where: { previous in
                        let gap = previous.bounds.minY - line.bounds.maxY
                        return gap >= -1 && gap < line.bounds.height * 0.70
                            && abs(previous.bounds.minX - line.bounds.minX) < line.bounds.height
                            && abs(previous.bounds.height - line.bounds.height) < 1.3 && previous.isProse
                            && previous.words.last?.last?.isLowercase == true
                    })
                else { return nil }
            }
            // PDFKit may split a change of font within one heading. Check the actual title even
            // when a bare “Table 2” ends at the font switch in a prose reference.
            var caption = line
            if prefix.title.isEmpty,
                let continuation = lines.filter({
                    abs($0.bounds.midY - line.bounds.midY) < line.bounds.height * 0.35
                        && $0.bounds.minX >= line.bounds.maxX - 1
                        && $0.bounds.minX - line.bounds.maxX < line.bounds.height * 1.5
                }).min(by: { $0.bounds.minX < $1.bounds.minX })
            {
                caption = Line(
                    text: line.text + " " + continuation.text, bounds: line.bounds.union(continuation.bounds),
                    range: line.range)
                guard let joined = marker(in: caption.text), joined.looksLikeHeading else { return nil }
                // The navigation range must refer only to the original line, even with a joined title.
                prefix = Marker(
                    label: prefix.label, range: prefix.range, separator: joined.separator, title: joined.title)
            }
            return (caption, prefix)
        }
        guard !anchors.isEmpty else { return [] }
        // Keep work bounded on index pages containing hundreds of figure references.
        guard anchors.count <= 16, let ink = PDFCaptionInk(page) else {
            return anchors.compactMap { line, prefix in
                guard !prefix.separator.isEmpty else { return nil }
                let range = NSRange(location: line.range.location + prefix.range.location, length: prefix.range.length)
                return PDFCaptionRegion(
                    label: prefix.label, captionBounds: line.bounds, captionRange: range, sourceBounds: nil)
            }
        }
        for stamp in marginStamps { try ink.excludeIsolatedStamp(stamp) }
        let captionOffsets = Set(anchors.map { $0.0.range.location })
        let headings = try anchors.map { line, prefix in
            // A bare, centered number can introduce a multi-line title that spans both columns.
            let detachedTitle =
                prefix.title.isEmpty
                ? lines.filter { next in
                    let gap = line.bounds.minY - next.bounds.maxY
                    return gap >= -1 && gap < line.bounds.height * 0.75
                        && abs(next.bounds.midX - line.bounds.midX) < line.bounds.height
                        && next.bounds.width > line.bounds.width * 1.4 && next.isProse
                }.max { $0.bounds.midY < $1.bounds.midY } : nil
            let lane = column(for: detachedTitle ?? line, lines: lines, box: box)
            let local = lines.filter { $0.bounds.midX > lane.minX && $0.bounds.midX < lane.maxX }
            let extent = try captionExtent(line, lines: local, captionOffsets: captionOffsets, ink: ink)
            return (
                line: line, prefix: prefix, lane: lane, local: local, extent: extent,
                detachedTitle: detachedTitle != nil
            )
        }
        var choices = [[CGRect]]()
        for heading in headings {
            try Task.checkCancellation()
            let neighbors = headings.filter { $0.line.range != heading.line.range }.map(\.extent)
            let bounds = try [true, false].compactMap { above in
                try candidate(
                    above: above, caption: heading.line, extent: heading.extent, lane: heading.lane,
                    lines: heading.local, ink: ink, label: heading.prefix.label, otherCaptions: neighbors)
            }
            choices.append(bounds)
        }
        // Adjacent captions may both see the drawing between them. An unambiguous anchor
        // rules that drawing out for its neighbor only if both measured the same complete box.
        for _ in headings {
            let assigned = choices.compactMap { $0.count == 1 ? $0[0] : nil }
            var resolved = false
            for i in choices.indices where choices[i].count == 2 {
                let free = choices[i].filter { bounds in
                    !assigned.contains { other in
                        bounds.insetBy(dx: -2, dy: -2).contains(other) && other.insetBy(dx: -2, dy: -2).contains(bounds)
                    }
                }
                if free.count == 1 {
                    choices[i] = free
                    resolved = true
                }
            }
            if !resolved { break }
        }
        let results = zip(headings, choices).compactMap { heading, options -> PDFCaptionRegion? in
            // Without a separator, require an independently measured drawing or a detached title.
            guard !heading.prefix.separator.isEmpty || !options.isEmpty || heading.detachedTitle else { return nil }
            let prefix = heading.prefix
            let range = NSRange(
                location: heading.line.range.location + prefix.range.location, length: prefix.range.length)
            return PDFCaptionRegion(
                label: prefix.label, captionBounds: heading.line.bounds, captionRange: range,
                sourceBounds: options.count == 1 ? options[0] : nil)
        }
        // Neighbouring captions must never claim the same drawing (stacked floats, subpanels, etc.).
        return results.map { region in
            guard let crop = region.sourceBounds,
                results.contains(where: {
                    $0.captionRange != region.captionRange
                        && ($0.sourceBounds?.intersects(crop) == true || crop.intersects($0.captionBounds))
                })
            else { return region }
            return PDFCaptionRegion(
                label: region.label, captionBounds: region.captionBounds, captionRange: region.captionRange,
                sourceBounds: nil)
        }
    }

    /// Find the edge of the neighbouring column from actual prose, including asymmetrical wrap-around layouts.
    private static func column(for caption: Line, lines: [Line], box: CGRect) -> CGRect {
        let anchor = caption.bounds
        let right = anchor.midX > box.midX
        guard right ? anchor.minX > box.minX + box.width * 0.27 : anchor.maxX < box.maxX - box.width * 0.27
        else { return box }
        let peers = lines.filter {
            $0.isProse && $0.bounds.width > box.width * 0.21
                && abs($0.bounds.midY - anchor.midY) < box.height * 0.24
                && (right ? $0.bounds.maxX < anchor.minX - 3 : $0.bounds.minX > anchor.maxX + 3)
        }
        guard peers.count >= 2 else { return box }
        let edges = peers.map { right ? $0.bounds.maxX : $0.bounds.minX }.sorted()
        let edge = right ? edges[edges.count * 4 / 5] + 2 : edges[edges.count / 5] - 2
        return CGRect(
            x: right ? edge : box.minX, y: box.minY, width: right ? box.maxX - edge : edge - box.minX,
            height: box.height)
    }

    private static func captionExtent(_ caption: Line, lines: [Line], captionOffsets: Set<Int>, ink: PDFCaptionInk)
        throws -> CGRect
    {
        var extent = caption.bounds
        var previous = caption
        for next in lines.sorted(by: { $0.bounds.midY > $1.bounds.midY }) where next.bounds.midY < caption.bounds.midY {
            let b = next.bounds
            let gap = previous.bounds.minY - b.maxY
            if gap > max(4, caption.bounds.height * 0.55) { break }
            // A bold or enlarged marker often makes PDFKit's first line box taller than the body
            // of the caption. Subsequent lines should follow the preceding line's type size and lane.
            let first = previous.range == caption.range
            let heightTolerance =
                first ? max(1.5, previous.bounds.height * 0.28) : max(1.3, previous.bounds.height * 0.16)
            guard gap >= -1.5, abs(b.height - previous.bounds.height) < heightTolerance,
                abs(b.minX - extent.minX) < 5 || abs(b.midX - extent.midX) < 5,
                b.maxX <= extent.maxX + 12 || first && !previous.isProse,
                !captionOffsets.contains(next.range.location)
            else { continue }
            if gap > 0.5 {
                // An underlined word in a caption can paint the entire width of one PDFKit
                // fragment. A table rule should span a substantial portion of the whole heading.
                let divider = CGRect(x: extent.minX, y: b.maxY, width: extent.width, height: gap)
                let ruleWidth = max(30, extent.width * 0.32, b.width * 0.55)
                if try ink.strips(in: divider).contains(where: { $0.longestStroke > ruleWidth }) { break }
            }
            extent = extent.union(b)
            previous = next
        }
        return extent
    }

    private static func candidate(
        above: Bool, caption: Line, extent: CGRect, lane: CGRect, lines: [Line], ink: PDFCaptionInk, label: String,
        otherCaptions: [CGRect]
    ) throws -> CGRect? {
        let anchor = above ? extent.maxY : extent.minY
        let box = ink.box
        let inDirection = lines.filter { above ? $0.bounds.minY >= anchor : $0.bounds.maxY <= anchor }
        // A tall marker or superscript can enlarge the first text box even if the adjacent
        // body is the same type size as the caption's regular continuation lines.
        let captionHeight =
            lines.filter { extent.contains($0.bounds) && $0.bounds.width > extent.width * 0.4 }
            .map(\.bounds.height).min() ?? caption.bounds.height
        let paragraphLines = inDirection.filter {
            $0.isProse && $0.words.count >= 6
                && $0.words.filter { $0.first?.isLowercase == true }.count >= 3
                && $0.bounds.width >= lane.width * 0.40 && $0.bounds.height >= captionHeight * 0.86
        }
        let largeLines = paragraphLines.filter { line in
            line.bounds.width >= lane.width * 0.55
                || paragraphLines.contains { other in
                    other.range != line.range && abs(other.bounds.minX - line.bounds.minX) < 5
                        && abs(other.bounds.height - line.bounds.height) < 1.3
                        && abs(other.bounds.midY - line.bounds.midY) < line.bounds.height * 2
                }
        }
        var far = above ? box.maxY : box.minY
        for other in otherCaptions where other.midX > lane.minX && other.midX < lane.maxX {
            if above, other.minY >= anchor { far = min(far, other.minY - 1) }
            if !above, other.maxY <= anchor { far = max(far, other.maxY + 1) }
        }
        for line in inDirection {
            let b = line.bounds
            let header =
                b.minY > box.maxY - box.height * 0.10 && b.width > box.width * 0.32
                && abs(b.midX - box.midX) < box.width * 0.08 && line.isProse
            let proseEdge = largeLines.contains {
                abs($0.bounds.minX - b.minX) < 4 && abs($0.bounds.height - b.height) < 1.2
                    && abs($0.bounds.midY - b.midY) < b.height * 2
            }
            let startsSection =
                line.text.prefixMatch(of: /^\s*\d+(?:\.\d+)+\s+\p{Lu}/) != nil
                && largeLines.contains { next in
                    let gap = b.minY - next.bounds.maxY
                    return gap >= -1 && gap < b.height * 1.5 && abs(next.bounds.minX - b.minX) < 4
                }
            if header || proseEdge || startsSection {
                if above { far = min(far, b.minY - (header ? 4 : 0.6)) } else { far = max(far, b.maxY + 1) }
            }
        }
        let near = anchor + (above ? 0.5 : -0.5)
        guard (above ? far - near : near - far) > 25 else { return nil }
        let band = CGRect(x: lane.minX, y: min(far, near), width: lane.width, height: abs(far - near))
        var strips = try ink.strips(in: band)
        if !above { strips.reverse() }
        func distance(_ strip: PDFCaptionInk.Strip) -> CGFloat {
            above ? strip.bounds.minY - near : near - strip.bounds.maxY
        }
        // PDFKit font bounds occasionally miss sub-point antialiasing from the caption itself.
        if let first = strips.first, distance(first) < 1.5, first.bounds.height < 2, first.longestStroke < 12 {
            strips.removeFirst()
        }
        guard let first = strips.first, distance(first) < max(30, caption.bounds.height * 3) else { return nil }
        var drawing = first.bounds
        var accepted = [first]
        for strip in strips.dropFirst() {
            let gap = above ? strip.bounds.minY - drawing.maxY : drawing.minY - strip.bounds.maxY
            if gap > max(15, caption.bounds.height * 1.4) {
                // A second nearby painted part could be a detached legend or panel.
                if gap < max(18, caption.bounds.height * 1.9), strip.bounds.height > 3 { return nil }
                if gap < 45, strip.bounds.height > 15, strip.longestStroke > 20 { return nil }
                break
            }
            accepted.append(strip)
            drawing = drawing.union(strip.bounds)
        }
        guard drawing.width > 36, drawing.height > 24, drawing.height < box.height * 0.80,
            drawing.minX > lane.minX + 1.5, drawing.maxX < lane.maxX - 1.5,
            (above ? far - drawing.maxY : drawing.minY - far) > 1
        else { return nil }
        // In a row of small plots, each axis may be much shorter than the caption line. Look for
        // repeated, vertically aligned tick labels as separate evidence before accepting shorter strokes.
        let ticks = inDirection.filter { line in
            line.bounds.height < caption.bounds.height * 0.75 && drawing.contains(line.bounds)
                && line.text.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /[−-]?\d+(?:\.\d+)?/) != nil
        }
        let hasAxis =
            label.hasPrefix("图")
            && ticks.contains { tick in
                ticks.filter {
                    abs($0.bounds.maxX - tick.bounds.maxX) < 2
                        && abs($0.bounds.midY - tick.bounds.midY) > tick.bounds.height
                }.count >= 2
            }
        let broad = accepted.filter { $0.longestStroke >= max(20, drawing.width * (hasAxis ? 0.08 : 0.21)) }
        let rules = broad.filter { $0.bounds.height <= 2.5 && $0.longestStroke > drawing.width * 0.55 }
        let hasDrawing =
            broad.contains { $0.drawnRows >= 5 }
            || broad.filter { $0.bounds.height > 16 && $0.drawnRows >= 2 }.count >= 2 || rules.count >= 2
        guard hasDrawing else { return nil }
        // A short prose line between the caption and graphic can fall below paragraph-width thresholds.
        // Capturing it with the graphic would hide article text and make an incorrect source association.
        let graphicEnvelope = broad.reduce(CGRect.null) { $0.union($1.bounds) }
        if inDirection.contains(where: {
            drawing.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) && $0.isProse
                && $0.bounds.height >= caption.bounds.height * 0.85
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).last == "."
                && $0.words.filter { $0.first?.isLowercase == true }.count >= 3
                && !$0.bounds.intersects(graphicEnvelope)
        }) {
            return nil
        }
        if label.hasPrefix("表") {
            // A ruled table has more than just its outline. Also support a ruled grid rendered as one strip.
            let cells = inDirection.filter { drawing.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
            guard cells.count >= 3 || (accepted.count == 1 && broad.first?.drawnRows ?? 0 >= 10) else { return nil }
        }
        // A lane or prose barrier cutting a glyph would publish a clipped object.
        let protected = drawing.insetBy(dx: -3, dy: -3).intersection(band)
        guard
            !inDirection.contains(where: {
                $0.bounds.intersects(drawing) && !protected.insetBy(dx: -2, dy: -2).contains($0.bounds)
            })
        else { return nil }
        return drawing.insetBy(dx: -3, dy: -2).intersection(band)
    }
}
