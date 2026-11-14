import Foundation
import Testing

@testable import PaperReaderKit

@Test func readingCountsUnionAndClipsToDay() {
    let id = UUID()
    let start = Date(timeIntervalSince1970: 10000)
    let entries = [
        ReadingEntry(paperID: id, start: start.addingTimeInterval(-30), end: start.addingTimeInterval(60)),
        ReadingEntry(paperID: id, start: start.addingTimeInterval(30), end: start.addingTimeInterval(120)),
        ReadingEntry(paperID: id, start: start.addingTimeInterval(200), end: start.addingTimeInterval(300)),
    ]
    #expect(ReadingMetrics.seconds(entries, during: DateInterval(start: start, duration: 250)) == 170)
}
