import Testing

@testable import PaperReaderUI

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
