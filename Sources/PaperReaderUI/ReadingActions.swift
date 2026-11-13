import Foundation
import PaperReaderKit

extension ReaderModel {
    public func touch() {
        lastInteraction = Date()
        if readingStart == nil && isActive { beginReading() }
    }
    public func beginReading() {
        guard isActive, selectedSection == "library", let id = selectedPaperID, readingStart == nil else { return }
        readingPaper = id
        readingStart = Date()
        lastInteraction = Date()
    }
    public func endReading() {
        guard let start = readingStart, let id = readingPaper else { return }
        let end = min(Date(), lastInteraction.addingTimeInterval(300))
        readingStart = nil
        readingPaper = nil
        if end > start {
            state.reading.append(ReadingEntry(paperID: id, start: start, end: end))
            Task { await save() }
        }
    }
    public func setActive(_ active: Bool) {
        isActive = active
        if active {
            beginReading()
        } else {
            endReading()
            for task in translationTasks.values { task.cancel() }
        }
    }
    public func tick() {
        if Date().timeIntervalSince(lastInteraction) > 300 {
            endReading()
        } else if readingStart != nil {
            // Persist at most one minute of unsaved reading time across an unexpected exit.
            let previousInteraction = lastInteraction
            endReading()
            beginReading()
            lastInteraction = previousInteraction
        }
    }
    public func addReading(paperID: UUID, date: Date, minutes: Double) {
        state.reading.append(
            ReadingEntry(
                paperID: paperID, start: date, end: date.addingTimeInterval(max(1, minutes) * 60), manual: true))
        Task { await save() }
    }
    public func deleteReading(_ id: UUID) {
        state.reading.removeAll { $0.id == id }
        Task { await save() }
    }
}
