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
