import Foundation
import Testing

@testable import PaperReaderUI

@MainActor struct ShelfCoverFlightTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    // Level endpoints make the upward lift distinguishable from travel to the panel.
    private let shelf = CGRect(x: 900, y: 410, width: 154, height: 220)
    private let panel = CGRect(x: 260, y: 340, width: 252, height: 360)

    @Test func coldCoverWaitsForArtworkBeforeStartingTheWholeJourney() {
        let waiting = ShelfCoverFlight(onShelf: shelf)
        let ready = Date.now.addingTimeInterval(2)
        expectCover(waiting.pose(at: ready, destination: panel), in: shelf)
        let moving = waiting.lifted(at: ready)
        expectCover(moving.pose(at: ready, destination: panel), in: shelf)
        #expect(moving.endsAt > ready)
        expectCover(moving.pose(at: moving.endsAt, destination: panel), in: panel)
    }

    @Test func coverLiftsAndTravelsBetweenShelfAndPreview() {
        let opening = ShelfCoverFlight(source: shelf, openingAt: start)
        expectCover(opening.pose(at: start, destination: panel), in: shelf)
        expectCover(opening.pose(at: opening.endsAt, destination: panel), in: panel)

        let duration = opening.endsAt.timeIntervalSince(start)
        #expect(duration > 0)
        let samples = (1..<10).map { step in
            opening.pose(at: start.addingTimeInterval(duration * Double(step) / 10), destination: panel)
        }
        #expect(samples.contains { $0.center.y < shelf.midY - 1 })
        #expect(samples.contains { abs($0.tilt) > 0.01 })
        #expect(
            samples.contains { pose in
                (panel.midX + 1..<shelf.midX - 1).contains(pose.center.x)
                    && (shelf.width + 1..<panel.width - 1).contains(pose.width)
            })
    }

    @Test func releaseAndPressDuringFlightBothReverseFromCurrentPose() {
        let opening = ShelfCoverFlight(source: shelf, openingAt: start)
        let release = start.addingTimeInterval(opening.endsAt.timeIntervalSince(start) * 0.6)
        let returning = opening.reversed(at: release, landing: shelf)
        expectSamePose(opening.pose(at: release, destination: panel), returning.pose(at: release, destination: panel))

        let press = release.addingTimeInterval(returning.endsAt.timeIntervalSince(release) / 2)
        #expect(returning.progress(at: press) < returning.progress(at: release))
        let reopening = returning.reversed(at: press, landing: shelf)
        expectSamePose(returning.pose(at: press, destination: panel), reopening.pose(at: press, destination: panel))
        #expect(reopening.progress(at: reopening.endsAt) > reopening.progress(at: press))
        expectCover(reopening.pose(at: reopening.endsAt, destination: panel), in: panel)
    }

    @Test func returnLandsOnUpdatedShelfPositionEvenWhenReleasedEarly() {
        let opening = ShelfCoverFlight(source: shelf, openingAt: start)
        let release = start.addingTimeInterval(opening.endsAt.timeIntervalSince(start) * 0.45)
        let landing = shelf.offsetBy(dx: 3, dy: 6)
        let returning = opening.reversed(at: release, landing: landing)
        expectSamePose(opening.pose(at: release, destination: panel), returning.pose(at: release, destination: panel))
        expectCover(returning.pose(at: returning.endsAt, destination: panel), in: landing)
    }

    private func expectCover(_ pose: ShelfCoverPose, in frame: CGRect) {
        #expect(abs(pose.center.x - frame.midX) < 0.01)
        #expect(abs(pose.center.y - frame.midY) < 0.01)
        #expect(abs(pose.width - frame.width) < 0.01)
        #expect(abs(pose.tilt) < 0.01)
    }

    private func expectSamePose(_ first: ShelfCoverPose, _ second: ShelfCoverPose) {
        #expect(abs(first.center.x - second.center.x) < 0.01)
        #expect(abs(first.center.y - second.center.y) < 0.01)
        #expect(abs(first.width - second.width) < 0.01)
        #expect(abs(first.tilt - second.tilt) < 0.01)
    }
}
