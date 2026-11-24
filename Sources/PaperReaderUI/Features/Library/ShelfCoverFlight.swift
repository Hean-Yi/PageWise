import SwiftUI

struct ShelfCoverPose: Equatable {
    let center: CGPoint
    let width: CGFloat
    let tilt: Double
}

/// One reversible path for the book, its shadow and the preview's reveal.
struct ShelfCoverFlight: Equatable {
    static let coordinateSpace = "bookshelf-preview"
    private(set) var awaitingLift = false
    let typesetWidth: CGFloat
    let returning: Bool
    private let startedAt: Date
    private let startProgress: CGFloat
    private let startSlot: CGRect
    private let endSlot: CGRect

    init(source: CGRect, openingAt date: Date) {
        self.init(width: source.width, start: 0, returning: false, date: date, from: source, to: source)
    }

    init(onShelf source: CGRect) {
        self.init(source: source, openingAt: .now)
        awaitingLift = true
    }

    func lifted(at date: Date) -> Self { Self(source: startSlot, openingAt: date) }

    private init(width: CGFloat, start: CGFloat, returning: Bool, date: Date, from: CGRect, to: CGRect) {
        typesetWidth = width
        startProgress = start
        self.returning = returning
        startedAt = date
        startSlot = from
        endSlot = to
    }

    private var fullTravelTime: TimeInterval { returning ? 0.36 : 0.48 }
    var endsAt: Date {
        startedAt.addingTimeInterval(fullTravelTime * (returning ? startProgress : 1 - startProgress))
    }

    func progress(at date: Date) -> CGFloat {
        if awaitingLift { return 0 }
        if date >= endsAt { return returning ? 0 : 1 }
        let elapsed = max(0, date.timeIntervalSince(startedAt)) / fullTravelTime
        return returning ? startProgress - elapsed : startProgress + elapsed
    }

    func reversed(at date: Date, landing: CGRect) -> Self {
        let currentSlot = slot(at: date)
        return Self(
            width: typesetWidth, start: progress(at: date), returning: !returning, date: date,
            from: currentSlot, to: returning ? currentSlot : landing)
    }

    func pose(at date: Date, destination: CGRect) -> ShelfCoverPose {
        let source = slot(at: date)
        let p = progress(at: date)
        let travel = Self.ease(p, from: 0.09, to: 1)
        let lift = p == 0 || p == 1 ? 0 : sin(.pi * p)
        let width = source.width + (destination.width - source.width) * travel
        return ShelfCoverPose(
            center: CGPoint(
                x: source.midX + (destination.midX - source.midX) * travel,
                y: source.midY + (destination.midY - source.midY) * travel - 26 * lift),
            width: width * (1 + 0.035 * lift),
            tilt: (destination.midX >= source.midX ? 1 : -1) * 1.2 * lift)
    }

    private static func ease(_ progress: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
        let t = min(1, max(0, (progress - from) / (to - from)))
        return t * t * (3 - 2 * t)
    }

    // The shelf can settle its hover offset or reflow when resized during a preview.
    // Blend that correction on the way back, keeping the exact pose at the turn.
    private func slot(at date: Date) -> CGRect {
        guard startSlot != endSlot, startProgress > 0 else { return endSlot }
        let t = Self.ease(1 - progress(at: date) / startProgress, from: 0, to: 1)
        return CGRect(
            x: startSlot.minX + (endSlot.minX - startSlot.minX) * t,
            y: startSlot.minY + (endSlot.minY - startSlot.minY) * t,
            width: startSlot.width + (endSlot.width - startSlot.width) * t,
            height: startSlot.height + (endSlot.height - startSlot.height) * t)
    }
}
