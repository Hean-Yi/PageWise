import Testing

@testable import PaperReaderUI

#if os(macOS)
    import CoreGraphics
    import SwiftUI
#endif

@Test func reflowBookOpensThenTurnsThreePagesBeforeClosingTheBackCover() {
    #expect(ReflowBookPose.reading(elapsed: 0, from: .closed) == .closed)
    let opening = ReflowBookPose.reading(elapsed: 0.44, from: .closed)
    #expect(opening.front > 0 && opening.front < 1 && opening.leaf == 0 && opening.back == 0)
    #expect(ReflowBookPose.reading(elapsed: 1, from: .closed) == .open)

    var previousPageProgress = 0.0
    for start in [1.12, 2.72, 4.32] {
        let early = ReflowBookPose.reading(elapsed: start + 0.44, from: .closed)
        let late = ReflowBookPose.reading(elapsed: start + 1.1, from: .closed)
        #expect(early.front == 1 && late.front == 1 && early.back == 0 && late.back == 0)
        #expect(early.leaf > 0 && early.leaf < late.leaf && late.leaf < 1)
        #expect(previousPageProgress < early.readFraction && early.readFraction < late.readFraction)
        previousPageProgress = late.readFraction
    }

    let closingBack = ReflowBookPose.reading(elapsed: 6.52, from: .closed)
    #expect(closingBack.front == 1 && closingBack.leaf == 1 && closingBack.back > 0 && closingBack.back < 1)
}

@Test func reflowBookHoldsTheBackCoverThenTurnsTheWholeBookToTheFront() {
    let back = ReflowBookPose.reading(elapsed: 7.4, from: .closed)
    #expect(back == .backCover && back != .closed)
    #expect(back.front == 1 && back.leaf == 1 && back.back == 1)

    let first = ReflowBookPose.reading(elapsed: 8.1, from: .closed)
    let last = ReflowBookPose.reading(elapsed: 8.5, from: .closed)
    #expect(first.front < 1 && first.front > last.front && last.front > 0)
    #expect(first.front == first.leaf && first.leaf == first.back)
    #expect(last.front == last.leaf && last.leaf == last.back)

    let front = ReflowBookPose.reading(elapsed: 9.0, from: .closed)
    #expect(front == .closed && front.front == 0 && front.leaf == 0 && front.back == 0)
    #expect(ReflowBookPose.reading(elapsed: 9.2 + 1, from: .closed) == .open)
}

@Test(arguments: [0.44, 1.9, 6.52, 7.4, 8.3])
func reflowBookPausesDirectlyToTheFrontAndRestartsWithoutJumping(at time: Double) {
    let visible = ReflowBookPose.reading(elapsed: time, from: .closed)
    #expect(visible.closing(elapsed: 0) == visible)
    let midClose = visible.closing(elapsed: ReflowBookPose.closeDuration / 2)
    #expect(midClose.front > 0 && midClose.front < visible.front)
    #expect(midClose.leaf >= 0 && midClose.leaf <= visible.leaf)
    #expect(midClose.back >= 0 && midClose.back <= visible.back)
    #expect(visible.closing(elapsed: ReflowBookPose.closeDuration) == .closed)

    #expect(ReflowBookPose.reading(elapsed: 0, from: midClose) == midClose)
    let restarted = ReflowBookPose.reading(elapsed: 0.001, from: midClose)
    #expect(abs(restarted.front - midClose.front) < 0.01)
    #expect(abs(restarted.leaf - midClose.leaf) < 0.01)
    #expect(abs(restarted.back - midClose.back) < 0.01)
}

#if os(macOS)
    @MainActor @Test func reflowBookCoversStandUprightWithRoomForTheTurningPage() throws {
        let frame = CGSize(width: 224, height: 168)
        let turning = ReflowBookPose.reading(elapsed: 1.92, from: .closed)
        // Sample the opening cover near 0.1 and 0.6, the closing back near 0.65,
        // and the entire book before, on and after the edge-on frame.
        let moving = [0.19, 0.54, 6.19, 6.64, 8.14, 8.26, 8.58].map {
            ReflowBookPose.reading(elapsed: $0, from: .closed)
        }
        let paused = [turning, .reading(elapsed: 6.64, from: .closed), .backCover].map {
            $0.closing(elapsed: ReflowBookPose.closeDuration * 0.4)
        }
        for pose in [.closed, .backCover, .open, turning] + moving + paused {
            let renderer = ImageRenderer(
                content: ReflowBookIllustration(pose: pose).frame(width: frame.width, height: frame.height))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let columns = try reflowBookContour(in: image)
            let left = try #require(columns.first?.x)
            let right = try #require(columns.last?.x)
            let top = try #require(columns.map(\.first).min())
            let bottom = try #require(columns.map(\.last).max())
            let width = right - left + 1

            #expect(left > 2 && right < image.width - 3 && top > 2 && bottom < image.height - 3)
            #expect(
                abs((left + right) / 2 - image.width / 2) < 6,
                "Horizontal centre at front \(pose.front), leaf \(pose.leaf), back \(pose.back)")
            #expect(abs((top + bottom) / 2 - image.height / 2) < 15)
            if pose == .closed || pose == .backCover {
                #expect((85...115).contains(width) && (94...128).contains(bottom - top + 1))
                let quarter = columns.count / 4
                let a = columns[quarter]
                let b = columns[columns.count - 1 - quarter]
                #expect(abs(a.first - b.first) <= 1 && abs(a.last - b.last) <= 1)
            } else if pose == .open || pose == turning {
                #expect(width > 180)
            }
        }
    }

    private func reflowBookContour(in image: CGImage) throws -> [(x: Int, first: Int, last: Int)] {
        let stride = image.width * 4
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let rgba = Data(bytes: try #require(context.data), count: stride * image.height)
        let rows = 0..<image.height
        // The corner supplies the canvas colour for this frame. Ignore faint antialiasing at the ink boundary.
        return (0..<image.width).compactMap { x in
            let painted = { (y: Int) in
                let offset = y * stride + x * 4
                return (0..<3).contains { channel in abs(Int(rgba[offset + channel]) - Int(rgba[channel])) > 20 }
            }
            guard let first = rows.first(where: painted), let last = rows.last(where: painted) else { return nil }
            return (x, first, last)
        }
    }
#endif
