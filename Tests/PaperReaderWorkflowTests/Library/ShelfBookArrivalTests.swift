import Testing

@testable import PaperReaderUI

@MainActor struct ShelfBookArrivalTests {
    @Test func visibleBooksStartCloseTogetherAndReachTheirSlotsOnEveryShelfSize() {
        for columns in [1, 2, 4, 10] {
            for position in [0, 1, 5, 23, 1_003] {
                let start = ShelfBookArrival.lift(at: 0, position: position, columns: columns)
                let moving = ShelfBookArrival.lift(at: 0.09, position: position, columns: columns)
                let landed = ShelfBookArrival.lift(at: ShelfBookArrival.duration, position: position, columns: columns)
                #expect(start == 1)
                #expect(0 < moving && moving < 1)
                #expect(abs(landed) < 0.000_001)
            }
        }
    }

    @Test func adjacentBooksInEitherDirectionHaveDistinctArrivalTimes() {
        let leading = ShelfBookArrival.lift(at: 0.1, position: 0, columns: 3)
        #expect(leading < ShelfBookArrival.lift(at: 0.1, position: 1, columns: 3))
        #expect(leading < ShelfBookArrival.lift(at: 0.1, position: 3, columns: 3))
        #expect(leading == ShelfBookArrival.lift(at: 0.1, position: 2, columns: 3, fromTrailing: true))
    }
}
