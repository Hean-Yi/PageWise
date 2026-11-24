import Foundation
import PaperReaderKit

extension ReaderModel {
    public func addReading(paperID: UUID, date: Date, minutes: Double) {
        guard state.papers.contains(where: { $0.id == paperID }) else { return }
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
