import Synchronization

/// One gate per response. Only visible snapshots cross to the main actor; the service still reads every delta.
final class AssistantDraftCadence: Sendable {
    private struct Snapshot: Sendable {
        let text: String
        let nextUpdate: ContinuousClock.Instant
    }

    private let snapshot = Mutex<Snapshot?>(nil)

    func shouldPublish(_ text: String, at now: ContinuousClock.Instant = .now) -> Bool {
        guard !text.isEmpty else { return false }
        return snapshot.withLock { previous in
            if let previous, now < previous.nextUpdate || text == previous.text { return false }
            previous = Snapshot(text: text, nextUpdate: now.advanced(by: .milliseconds(100)))
            return true
        }
    }
}
