import Foundation
import PaperReaderKit

extension ReaderModel {
    public func touch() {
        lastInteraction = Date()
        if memorySleep.running { memorySleep.interrupt() }
        if readingStart == nil && isActive { beginReading() }
    }
    public func beginReading() {
        guard isActive, !showingReflowLoading, selectedSection == "library",
            let id = selectedPaperID, readingStart == nil
        else { return }
        readingPaper = id
        readingStart = Date()
        lastInteraction = Date()
    }
    public func endReading() {
        updateReadingPosition()
        scheduleWorkspaceSave(immediately: true)
        guard let start = readingStart, let id = readingPaper else { return }
        let end = min(Date(), lastInteraction.addingTimeInterval(300))
        readingStart = nil
        readingPaper = nil
        if end > start {
            state.reading.append(ReadingEntry(paperID: id, start: start, end: end))
            Task { await save() }
        }
    }
    public func setActive(_ active: Bool, suspendTranslation: Bool = true) {
        isActive = active
        researchBriefMaintenance.setActive(active)
        #if os(iOS)
            if !active { memorySleep.interrupt() }
        #endif
        if active {
            pdfDocumentTranslation.activate(session: pdfBilingual)
            beginReading()
        } else {
            Task { await flushReadingNotes() }
            invalidateSearchNavigation()
            endReading()
            if suspendTranslation {
                pdfBilingual.pause()
                pdfDocumentTranslation.suspend()
            }
            if suspendTranslation, !translationTasks.isEmpty {
                translationPauseReason = "应用进入后台，翻译已暂停"
                for id in translationTasks.keys { pauseReflow(id) }
            }
        }
    }
    public func tick() {
        if isActive { researchBriefMaintenance.tick() }
        if memorySleep.enabled { memorySleep.run(reader: self, automatic: true, withModel: true) }
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
}
