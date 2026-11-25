#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing

    @testable import PaperReaderUI

    @MainActor struct ReaderIconArtworkTests {
        @Test func favoriteBuildsSeparatePencilStrokesBeforeFillingTheGaps() {
            let bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
            let star = ReaderIcon.Glyph.favorite.drawing
            let interior = (0..<48).flatMap { y in
                (0..<48).map { x in CGPoint(x: CGFloat(x) / 2 + 0.25, y: CGFloat(y) / 2 + 0.25) }
            }.filter { star.contains($0) }
            var previous = Set<Int>()
            for progress: CGFloat in [0, 0.2, 0.52, 0.8, 1] {
                let pencil = FavoritePencilFill(progress: progress).path(in: bounds)
                let painted = Set(interior.indices.filter { pencil.contains(interior[$0]) })
                #expect(previous.isSubset(of: painted))
                if progress > 0 { #expect(painted.count > previous.count) }
                if progress == 0 { #expect(painted.isEmpty) }
                if progress == 1 { #expect(painted.count == interior.count) }
                if progress == 0.52 {
                    // At the centre, the first pass leaves visible paper between individual strokes.
                    var bands = 0
                    var onStroke = false
                    for y in stride(from: CGFloat(4), to: 18, by: 0.25) {
                        let covered = pencil.contains(CGPoint(x: 12, y: y))
                        if covered && !onStroke { bands += 1 }
                        onStroke = covered
                    }
                    #expect(bands >= 3)
                }
                previous = painted
            }
        }

        @Test func eachGlyphRendersDistinctHoverAndPressPosesInsideTheSameSlot() throws {
            let quiet = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            for glyph in ReaderIcon.Glyph.allCases {
                let idle = try pixels(glyph, .idle)
                let hovered = try pixels(glyph, .hovered)
                let pressed = try pixels(glyph, .pressed)
                #expect((idle == hovered) == quiet, "hover for \(glyph)")
                #expect((hovered == pressed) == quiet, "press for \(glyph)")
                #expect((idle == pressed) == quiet, "release for \(glyph)")
                #expect(try pixels(glyph, .pressed, enabled: false) == pixels(glyph, .idle, enabled: false))
            }
            for pose in [ReaderIconInteraction.idle, .hovered, .pressed] {
                #expect(try pixels(.favorite, pose, filled: true) != pixels(.favorite, pose))
            }
        }

        @Test func sidebarSelectionHasAVisibleShapeChangeForEveryDestination() throws {
            for glyph in [ReaderIcon.Glyph.library, .read, .favorite, .calendar, .notebook] {
                for pose in [ReaderIconInteraction.idle, .hovered, .pressed] {
                    let outline = try pixels(glyph, pose, sidebarSelected: false)
                    let inked = try pixels(glyph, pose, sidebarSelected: true)
                    #expect(outline != inked, "sidebar selection for \(glyph) in \(pose)")
                }
            }
        }

        @Test func paperSlipsBehindTheBinAndTheReadingLeafTurnsAcrossItsBinding() {
            let bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
            func ink(_ glyph: ReaderIcon.Glyph, _ pose: ReaderIconInteraction) -> CGRect {
                ReaderIconLayer(glyph: glyph, ink: .spot, state: pose).path(in: bounds).boundingRect
            }
            let liftedSheet = ink(.delete, .hovered)
            let droppedSheet = ink(.delete, .pressed)
            #expect(liftedSheet.minY < ink(.delete, .idle).minY)
            #expect(droppedSheet.maxY <= 9.11 && droppedSheet.minY > liftedSheet.minY)
            #expect(droppedSheet.height < liftedSheet.height)
            #expect(ink(.source, .hovered).minX > 11)
            #expect(ink(.source, .pressed).maxX <= 12.41)
        }

        @Test func dateAndHandwritingChangeWithinThePageWithoutMovingItsBinding() throws {
            // Inspect the printed area alone. Motion of the header or book spine cannot satisfy this check.
            let printArea = CGRect(x: 8, y: 11, width: 11, height: 8)
            for glyph in [ReaderIcon.Glyph.calendar, .notebook] {
                let frames = try [
                    pagePixels(glyph, progress: 0, background: .white, region: printArea),
                    pagePixels(
                        glyph, progress: ReaderIconPageAction.hoverProgress, background: .white, region: printArea),
                    pagePixels(
                        glyph, progress: 1, turns: glyph == .calendar ? 1 : 0, background: .white, region: printArea),
                ]
                #expect(Set(frames).count == 3, "printed area for \(glyph)")
            }
        }

        @Test func calendarSettlesContinuouslyOntoItsRestingPage() throws {
            let sheet = CGRect(x: 4, y: 9, width: 16, height: 12)
            for background in [Color.clear, .black] {
                let nearRest = try pagePixels(.calendar, progress: 0.0001, background: background, region: sheet)
                let rest = try pagePixels(.calendar, progress: 0, background: background, region: sheet)
                // One subpixel of antialiasing is acceptable. Removing an opaque page changes its entire interior.
                let changedChannels = zip(nearRest, rest).count { abs(Int($0.0) - Int($0.1)) > 8 }
                #expect(changedChannels < rest.count / 100, "discontinuous channels: \(changedChannels)")
            }
        }

        @Test func calendarHoverDoesNotAddAnotherLineAlongThePageEdge() throws {
            // This strip is beside the printed day, away from the corner that lifts.
            let edge = CGRect(x: 2, y: 11, width: 3, height: 6)
            func darkCoverage(at progress: CGFloat) throws -> Int {
                let rgba = try pagePixels(.calendar, progress: progress, background: .white, region: edge)
                return stride(from: 0, to: rgba.count, by: 4).count { rgba[$0] < 128 }
            }
            #expect(try darkCoverage(at: 0) == darkCoverage(at: ReaderIconPageAction.hoverProgress))
        }

        @Test func tearingCalendarPagesLeavesTheNewDatePrintedWhenThePointerLeaves() throws {
            let face = CGRect(x: 3, y: 9, width: 18, height: 12)
            func frame(turns: CGFloat, contact: CGFloat = 0) throws -> [UInt8] {
                try pagePixels(.calendar, progress: contact, turns: turns, background: .white, region: face)
            }
            let digit = CGRect(x: 8, y: 11, width: 6, height: 8)
            let hover = try pagePixels(
                .calendar, progress: ReaderIconPageAction.hoverProgress, background: .white, region: digit)
            let mouseDown = try pagePixels(.calendar, progress: 1, background: .white, region: digit)
            let activated = try pagePixels(.calendar, progress: 1, turns: 1, background: .white, region: digit)
            #expect(mouseDown == hover && activated != mouseDown)

            let restingPages = try (0..<31).map { try frame(turns: CGFloat($0)) }
            #expect(Set(restingPages).count == 31)
            let firstPageAfterCycle = try frame(turns: 31)
            #expect(firstPageAfterCycle == restingPages[0])
            for turn: CGFloat in [1, 2, 24, 25, 31] {
                for contact in [CGFloat(0), ReaderIconPageAction.hoverProgress, 1] {
                    let completed = try frame(turns: turn, contact: contact)
                    let lastFrame = try frame(turns: turn - 0.0001, contact: contact)
                    let oldPage = try frame(turns: turn - 1, contact: contact)
                    let stillOld = completed == oldPage
                    let discontinuous = zip(lastFrame, completed).count { abs(Int($0.0) - Int($0.1)) > 8 }
                    #expect(!stillOld && discontinuous < completed.count / 100, "turn \(turn), contact \(contact)")
                }
            }
        }

        @Test func liftedDatesKeepTheirCenterAndPrintedStrokeWidth() throws {
            for day in 1...31 {
                let rest = CalendarNumerals.path(day: day, lift: 0).boundingRect
                let lifted = CalendarNumerals.path(day: day, lift: 1).boundingRect
                #expect(abs(rest.midX - lifted.midX) < 0.01 && abs(rest.midY - lifted.midY) < 0.01)
                #expect(lifted.height > rest.height && lifted.height < 1.2 * rest.height)
            }

            // A short vertical slice across the seven's horizontal stroke measures actual rendered pen width.
            let bar = CGRect(x: 10, y: 10, width: 2, height: 4)
            func ink(at progress: CGFloat) throws -> Double {
                let rgba = try pagePixels(.calendar, progress: progress, background: .white, region: bar)
                return stride(from: 0, to: rgba.count, by: 4).reduce(0.0) { $0 + Double(255 - rgba[$1]) / 255 }
            }
            let rest = try ink(at: 0)
            let hovered = try ink(at: ReaderIconPageAction.hoverProgress)
            #expect(rest > 10 && abs(hovered - rest) < 2.5, "stroke coverage in pixels: \(rest) → \(hovered)")
        }

        @Test func writingStaysOnTheRightOfTheNotebookBinding() throws {
            let margin = CGRect(x: 0, y: 2, width: 6, height: 20)
            let rest = try pagePixels(.notebook, progress: 0, background: .clear, region: margin)
            for progress: CGFloat in [0.12, 0.24, ReaderIconPageAction.hoverProgress, 0.75, 1] {
                let frame = try pagePixels(.notebook, progress: progress, background: .clear, region: margin)
                let differs = frame != rest
                #expect(!differs, "left of the binding at progress \(progress)")
            }
        }

        private func pagePixels(
            _ glyph: ReaderIcon.Glyph, progress: CGFloat, turns: CGFloat = 0, background: Color, region: CGRect
        ) throws -> [UInt8] {
            let detail = ReaderIconPageAction(glyph: glyph, progress: progress, calendarTurns: turns)
                .frame(width: 24, height: 24).foregroundStyle(.black).background(background)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: detail)
            renderer.scale = 3
            let crop = try #require(renderer.cgImage?.cropping(to: region.applying(.init(scaleX: 3, y: 3))))
            let stride = crop.width * 4
            var bytes = [UInt8](repeating: 0, count: stride * crop.height)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try #require(
                    CGContext(
                        data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                        bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            return bytes
        }

        @Test func notebookPencilStaysInsideTheGlyphAndLeavesALegibleLineOnHover() {
            let frame = CGRect(x: 0, y: 0, width: 24, height: 24)
            let penStroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            let idle = ReaderIconPageAction.notebookInk(at: 0)
            let hover = ReaderIconPageAction.notebookInk(at: ReaderIconPageAction.hoverProgress)
            let lifting = ReaderIconPageAction.notebookInk(at: 0.9)
            let pressed = ReaderIconPageAction.notebookInk(at: 1)
            #expect(!idle.pencil.isEmpty && !idle.nib.isEmpty && idle.line.currentPoint == nil)
            #expect(hover.line.boundingRect.width >= pressed.line.boundingRect.width * 0.6)
            #expect(lifting.line == pressed.line && lifting.nib != pressed.nib)
            for frameIndex in 0...100 {
                let ink = ReaderIconPageAction.notebookInk(at: CGFloat(frameIndex) / 100)
                #expect(frame.contains(ink.pencil.strokedPath(penStroke).boundingRect))
            }
        }

        @Test func sidebarInkPassesOverDifferentPartsOfEachDrawing() {
            let bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
            for glyph in [ReaderIcon.Glyph.library, .read, .calendar, .notebook] {
                let plate = glyph.inkPlate
                let outline = glyph.drawing.strokedPath(StrokeStyle(lineWidth: 2.1, lineCap: .square, lineJoin: .round))
                let interior = (0..<48).flatMap { y in
                    (0..<48).map { x in CGPoint(x: CGFloat(x) / 2 + 0.25, y: CGFloat(y) / 2 + 0.25) }
                }.filter { plate.contains($0) || outline.contains($0) }
                var previous = Set<Int>()
                for frame in 0...20 {
                    let mask = SidebarIconFill(glyph: glyph, progress: CGFloat(frame) / 20).path(in: bounds)
                    let covered = Set(interior.indices.filter { mask.contains(interior[$0]) })
                    #expect(previous.isSubset(of: covered), "ink retreats for \(glyph) at \(frame)")
                    if frame == 0 { #expect(covered.isEmpty) }
                    if frame == 10 { #expect(!covered.isEmpty && covered.count < interior.count) }
                    if frame == 20 { #expect(covered.count == interior.count) }
                    previous = covered
                }
            }
        }

        @Test func downloadArrowLiftsOnceAndPressLandsInsideTheTray() {
            let times = (0...100).map { CGFloat($0) / 100 }
            let hover = times.map { ReaderActionGlyph.arrowOffset(.hovered, $0) }
            #expect(abs(hover[0]) < 0.001 && abs(hover[100]) < 0.001)
            #expect(hover[50] < -3 && hover[50] == hover.min())
            #expect(Array(hover[0...50]) == hover[0...50].sorted(by: >))
            #expect(Array(hover[50...100]) == hover[50...100].sorted())
            let touchdown = ReaderActionGlyph.arrowOffset(.pressed, 0.64)
            let settled = ReaderActionGlyph.arrowOffset(.pressed, 1)
            #expect(touchdown > settled && settled > 2)
            #expect(ReaderActionGlyph.arrowOffset(.idle, 0.5) == 0)
        }

        @Test func ellipsisInksItsThreeDotsInOrderAndSettles() {
            let moments: [CGFloat] = [0.28, 0.5, 0.72]
            for pose in [ReaderIconInteraction.hovered, .pressed] {
                for (index, time) in moments.enumerated() {
                    let dots = (0..<3).map { ReaderActionGlyph.dotPulse($0, pose, time) }
                    #expect(dots[index] > 0.99 && dots[index] == dots.max())
                    #expect(ReaderActionGlyph.dotPulse(index, pose, 1) < 0.001)
                    #expect(ReaderActionGlyph.dotPulse(index, .idle, time) == 0)
                }
            }
        }

        private func pixels(
            _ glyph: ReaderIcon.Glyph, _ pose: ReaderIconInteraction, filled: Bool = false,
            enabled: Bool = true, sidebarSelected: Bool? = nil
        ) throws -> Data {
            let icon = ReaderIcon(glyph, size: 18, filled: filled, sidebarSelected: sidebarSelected)
                .environment(\.readerIconInteraction, pose)
                .disabled(!enabled)
                .foregroundStyle(.black)
                .frame(width: 32, height: 32)
                .background(.white)
            let renderer = ImageRenderer(content: icon)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == 64 && image.height == 64)
            return try #require(image.dataProvider?.data) as Data
        }
    }
#endif
