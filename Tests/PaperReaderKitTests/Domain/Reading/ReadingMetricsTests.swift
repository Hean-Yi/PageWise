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

@Test func calendarGroupsRepeatedReadingsByPaperAndRetainsEditableRecords() throws {
    let paper = UUID()
    let other = UUID()
    let day = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86_400)
    let repeated = (1...10).map { index in
        let start = day.start.addingTimeInterval(Double(index * 120))
        return ReadingEntry(paperID: paper, start: start, end: start.addingTimeInterval(60), manual: index == 3)
    }
    let overlap = ReadingEntry(
        paperID: other, start: repeated.last!.start, end: repeated.last!.end.addingTimeInterval(30))
    let activity = ReadingMetrics.dailyActivity(repeated + [overlap], during: day)
    #expect(activity.papers.map(\.id) == [other, paper])
    let item = try #require(activity.papers.last)
    #expect(item.seconds == 600)
    #expect(item.entries.map(\.id) == repeated.reversed().map(\.id))
    #expect(item.entries.filter(\.manual).map(\.id) == [repeated[2].id])
    #expect(activity.papers.first?.seconds == 90)
    #expect(activity.seconds == 630)
}

@Test func calendarAssignsCrossMidnightReadingToBothDaysAndCountsOverlappingCorrectionsOnce() {
    let paper = UUID()
    let first = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86_400)
    let second = DateInterval(start: first.end, duration: 86_400)
    let crossing = ReadingEntry(
        paperID: paper, start: first.end.addingTimeInterval(-60), end: second.start.addingTimeInterval(90))
    let correction = ReadingEntry(
        paperID: paper, start: second.start, end: second.start.addingTimeInterval(120), manual: true)
    let empty = ReadingEntry(paperID: UUID(), start: second.start, end: second.start)
    let entries = [correction, empty, crossing]
    let yesterday = ReadingMetrics.dailyActivity(entries, during: first)
    let today = ReadingMetrics.dailyActivity(entries, during: second)
    #expect(yesterday.papers.map(\.seconds) == [60])
    #expect(yesterday.papers.first?.entries.map(\.id) == [crossing.id])
    #expect(today.papers.map(\.seconds) == [120])
    #expect(today.papers.first?.entries.map(\.id) == [correction.id, crossing.id])
    #expect(ReadingMetrics.dailyActivity([crossing], during: second).papers.first?.seconds == 90)
}
