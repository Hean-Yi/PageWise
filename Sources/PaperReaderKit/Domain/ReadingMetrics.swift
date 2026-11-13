import Foundation

public enum ReadingMetrics {
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
