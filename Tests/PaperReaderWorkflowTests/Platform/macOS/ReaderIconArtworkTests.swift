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
            let printArea = CGRect(x: 16, y: 22, width: 22, height: 16)
            for glyph in [ReaderIcon.Glyph.calendar, .notebook] {
                let frames = try [CGFloat(0), 0.48, 1].map { progress in
                    let detail = ReaderIconPageAction(glyph: glyph, progress: progress)
                        .frame(width: 24, height: 24).foregroundStyle(.black).background(.white)
                    let renderer = ImageRenderer(content: detail)
                    renderer.scale = 2
                    let crop = try #require(renderer.cgImage?.cropping(to: printArea))
                    return try #require(crop.dataProvider?.data) as Data
                }
                #expect(Set(frames).count == 3, "printed area for \(glyph)")
            }
        }

        @Test func notebookPencilStaysInsideTheGlyphAndLeavesALegibleLineOnHover() {
            let frame = CGRect(x: 0, y: 0, width: 24, height: 24)
            let penStroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            let idle = ReaderIconPageAction.notebookInk(at: 0)
            let hover = ReaderIconPageAction.notebookInk(at: 0.48)
            let pressed = ReaderIconPageAction.notebookInk(at: 1)
            #expect(!idle.pencil.isEmpty && !idle.nib.isEmpty && idle.line.currentPoint == nil)
            #expect(hover.line.boundingRect.width >= pressed.line.boundingRect.width * 0.6)
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
