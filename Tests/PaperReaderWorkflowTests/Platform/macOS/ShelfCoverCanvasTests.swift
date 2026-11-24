#if os(macOS)
    import AppKit
    import PaperReaderKit
    import QuartzCore
    import Testing

    @testable import PaperReaderUI

    @MainActor struct ShelfCoverCanvasTests {
        @Test func coldCoverWaitsInPlaceThenMovesOneTextureOnTheCompositor() async throws {
            _ = NSApplication.shared
            let canvas = ShelfCoverCanvas(frame: .zero)
            let viewport = CGSize(width: 940, height: 700)
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: viewport), styleMask: .borderless,
                backing: .buffered, defer: false)
            let host = try #require(window.contentView)
            host.wantsLayer = true
            host.addSubview(canvas)
            defer { withExtendedLifetime(window) {} }
            let shelf = CGRect(x: 680, y: 270, width: 154, height: 220)
            let destination = CGRect(x: 90, y: 200, width: 252, height: 360)
            let sourceCenter = CGPoint(x: shelf.midX, y: viewport.height - shelf.midY)
            let finalCenter = CGPoint(x: destination.midX, y: viewport.height - destination.midY)
            let paper = Paper(
                title: "How Paper Tiles Travel", digest: "compositor-fixture", originalPath: "tile.pdf",
                pageCount: 5, blocks: [], warnings: [], canReflow: false)
            let reading = ReadingProgress.resolve(paper: paper, workspace: PaperWorkspace(status: .reading))
            let waiting = ShelfCoverFlight(onShelf: shelf)
            var reports: [Bool] = []
            func input(_ flight: ShelfCoverFlight, reduced: Bool = false) -> ShelfFlyingCover {
                ShelfFlyingCover(
                    paper: paper, reading: reading, flight: flight, destination: destination,
                    reduceMotion: reduced, ready: { reports.append($0) })
            }

            canvas.configure(input(waiting), displayScale: 2)
            let book = try #require(canvas.layer?.sublayers?.first { $0.contents != nil })
            let texture = try #require(book.contents) as AnyObject
            #expect(CFGetTypeID(texture) == CGImage.typeID)
            #expect(book.bounds.size == shelf.size)
            #expect((book.animationKeys() ?? []).isEmpty)
            await Task.yield()
            #expect(reports.isEmpty)

            canvas.frame.size = viewport
            canvas.configure(input(waiting), displayScale: 2)
            for _ in 0..<20 where reports.isEmpty { await Task.yield() }
            #expect(reports == [true])
            #expect(book.position == sourceCenter)
            #expect((book.animationKeys() ?? []).isEmpty)

            // Schedule a fresh start after the texture has been rendered. The first keyframe must be at the shelf.
            let flight = waiting.lifted(at: .now.addingTimeInterval(0.1))
            canvas.configure(input(flight), displayScale: 2)
            CATransaction.flush()
            let group = try #require(book.animation(forKey: "coverFlight") as? CAAnimationGroup)
            let keyframes = try #require(group.animations as? [CAKeyframeAnimation])
            let movement = try #require(keyframes.first { $0.keyPath == "position" })
            let sizing = try #require(keyframes.first { $0.keyPath == "transform" })
            let points = try #require(movement.values as? [NSValue]).map(\.pointValue)
            let transforms = try #require(sizing.values as? [NSValue]).map(\.caTransform3DValue)
            let scales = transforms.map { hypot($0.m11, $0.m12) }
            #expect(group.duration > 0 && points.count == scales.count)
            #expect(points.first == sourceCenter && points.last == finalCenter)
            #expect(points.contains { $0.x < sourceCenter.x - 1 && $0.x > finalCenter.x + 1 && $0.y > sourceCenter.y })
            let finalScale = destination.width / shelf.width
            #expect(scales.contains { $0 > 1.01 && $0 < finalScale - 0.01 })
            #expect(book.position == finalCenter)

            canvas.configure(input(flight), displayScale: 2)
            let sameTextureAfterUpdate = texture === book.contents as AnyObject?
            #expect(sameTextureAfterUpdate)
            #expect(book.animation(forKey: "coverFlight")?.duration == group.duration)
            canvas.configure(input(flight, reduced: true), displayScale: 2)
            #expect((book.animationKeys() ?? []).isEmpty)
            #expect(book.position == finalCenter && abs(book.transform.m11 - finalScale) < 0.001)
            let sameTextureWhenReduced = texture === book.contents as AnyObject?
            #expect(sameTextureWhenReduced)
            #expect(reports == [true])
        }
    }
#endif
