import Testing

@testable import PaperReaderUI

@MainActor struct ShelfBookArrivalTests {
    @Test func coversSettleTogetherEvenFarDownTheShelf() {
        for columns in [1, 2, 4, 10] {
            for position in 0...2_000 {
                let delay = ShelfBookArrival.delay(position: position, columns: columns)
                #expect(delay >= 0 && delay <= 0.05)
                #expect(delay + ShelfBookArrival.duration < 0.35)
            }
        }
    }

    @Test func adjacentCoversStartInAStaggerAcrossColumnsAndRows() {
        let leading = ShelfBookArrival.delay(position: 0, columns: 3)
        #expect(leading == 0)
        #expect(ShelfBookArrival.delay(position: 1, columns: 3) > leading)
        #expect(ShelfBookArrival.delay(position: 3, columns: 3) > leading)
        #expect(ShelfBookArrival.delay(position: 9, columns: 3) == leading)
    }
}
