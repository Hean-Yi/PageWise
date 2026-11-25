import Testing

@testable import PaperReaderUI

@Test func reflowBookOpensTurnsOnePageAndClosesBeforeRepeating() {
    #expect(ReflowBookPose.reading(elapsed: 0, from: .closed) == .closed)
    let opening = ReflowBookPose.reading(elapsed: 0.44, from: .closed)
    #expect(opening.cover > 0 && opening.cover < 1 && opening.leaf == 0)
    #expect(ReflowBookPose.reading(elapsed: 1, from: .closed) == .open)
    let turning = ReflowBookPose.reading(elapsed: 1.5, from: .closed)
    #expect(turning.cover == 1 && turning.leaf > 0 && turning.leaf < 1)
    let closing = ReflowBookPose.reading(elapsed: 2.6, from: .closed)
    #expect(closing.cover < 1 && closing.cover > 0 && closing.leaf == closing.cover)
    #expect(ReflowBookPose.reading(elapsed: 3.2, from: .closed) == .closed)
    #expect(ReflowBookPose.reading(elapsed: 4.4, from: .closed) == .open)
}

@Test func pausingAndRestartingBookStartsAtTheVisiblePose() {
    let midTurn = ReflowBookPose.reading(elapsed: 1.56, from: .closed)
    #expect(midTurn.closing(elapsed: 0) == midTurn)
    let midClose = midTurn.closing(elapsed: ReflowBookPose.closeDuration / 2)
    #expect(midClose.cover < midTurn.cover && midClose.leaf < midTurn.leaf)
    #expect(ReflowBookPose.reading(elapsed: 0, from: midClose) == midClose)
    #expect(midTurn.closing(elapsed: ReflowBookPose.closeDuration) == .closed)
}
