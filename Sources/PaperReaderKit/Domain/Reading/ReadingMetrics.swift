import Foundation

public enum ReadingMetrics {
    public struct PaperActivity: Identifiable, Sendable {
        public let id: UUID
        public let seconds: TimeInterval
        public let entries: [ReadingEntry]
    }

    public static func dailyActivity(_ entries: [ReadingEntry], during day: DateInterval)
        -> (papers: [PaperActivity], seconds: TimeInterval)
    {
        let active = entries.filter { max(day.start, $0.start) < min(day.end, $0.end) }
        let recentFirst = active.sorted { lhs, rhs in
            let left = min(lhs.end, day.end)
            let right = min(rhs.end, day.end)
            if left != right { return left > right }
            if lhs.start != rhs.start { return lhs.start > rhs.start }
            return lhs.id < rhs.id
        }
        let grouped = Dictionary(grouping: recentFirst, by: \.paperID)
        var seen = Set<UUID>()
        let papers = recentFirst.compactMap { entry -> PaperActivity? in
            guard seen.insert(entry.paperID).inserted, let records = grouped[entry.paperID] else { return nil }
            return PaperActivity(id: entry.paperID, seconds: seconds(records, during: day), entries: records)
        }
        return (papers, seconds(active, during: day))
    }

    public static func seconds(_ entries: [ReadingEntry], during interval: DateInterval) -> TimeInterval {
        let ranges = entries.compactMap { entry -> DateInterval? in
            let start = max(interval.start, entry.start)
            let end = min(interval.end, entry.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var last: DateInterval?
        for range in ranges {
            if let existing = last, range.start <= existing.end {
                last = DateInterval(start: existing.start, end: max(existing.end, range.end))
            } else {
                total += last?.duration ?? 0
                last = range
            }
        }
        return total + (last?.duration ?? 0)
    }
}
