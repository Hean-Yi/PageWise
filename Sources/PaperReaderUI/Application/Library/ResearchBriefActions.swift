import Foundation
import PaperReaderKit

@MainActor final class ResearchBriefMaintenance {
    let index: ResearchBriefIndex
    private let notes: ReadingNoteMemoryIndex
    private let memories: ResearchMemory?
    private var loaded = false
    private var active = true
    private var requested = false
    private var auditing = false
    private var retry = false
    private var lastAudit = Date.distantPast
    var verification: (briefID: UUID, revision: UInt64, pending: Set<UUID>, valid: Bool)?
    private(set) var worker: Task<Void, Never>?

    init(store: LibraryStore, notes: ReadingNoteMemoryIndex, memories: ResearchMemory? = nil) {
        index = ResearchBriefIndex(store: store)
        self.notes = notes
        self.memories = memories
    }

    func sourcesChanged(now: Date = .now) {
        loaded = true
        requested = true
        if lastAudit == .distantPast { lastAudit = now }
        start()
    }

    func setActive(_ active: Bool, now: Date = .now) {
        self.active = active
        if active {
            tick(now: now)
            start()
        }
    }

    /// Uses the reader's existing minute/foreground lifecycle; reopening also reconciles missed work.
    func tick(now: Date = .now) {
        guard active, loaded else { return }
        let elapsed = now.timeIntervalSince(lastAudit)
        guard retry || elapsed < 0 || elapsed >= 6 * 3600 else { return }
        requested = true
        auditing = true
        lastAudit = now
        start()
    }

    private func start() {
        guard active, requested, worker == nil else { return }
        worker = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            while let self, self.active, self.requested {
                let audit = self.auditing
                self.requested = false
                self.auditing = false
                do {
                    try Task.checkCancellation()
                    let completed = try await self.index.maintain(
                        audit: audit, warming: self.notes, memories: self.memories)
                    if !completed {
                        // Another window owns the lease. Keep the request pending and retry
                        // after the short interval instead of waiting for the next six-hour audit.
                        self.requested = true
                        do {
                            try await Task.sleep(for: .milliseconds(500))
                        } catch {
                            self.retry = true
                            break
                        }
                        continue
                    }
                    self.retry = false
                } catch { self.retry = true }
            }
            self?.worker = nil
        }
    }

    deinit { worker?.cancel() }
}

extension ReaderModel {
    func researchBrief(matching query: String?, limit: Int = 4) async throws -> ResearchBrief {
        let revision = stateRevision
        let snapshot = state
        let pending = pendingImportIDs
        let term = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits: [Evidence]
        if let term, !term.isEmpty {
            hits = try await readingNoteIndex.search(
                query: term == "*" ? "" : term, state: snapshot, pending: pending,
                excluding: nil, paperID: nil, limit: 32, includeArchived: false)
        } else {
            hits = []
        }
        let brief = try await researchBriefMaintenance.index.brief(
            matching: term, limit: limit, state: snapshot, excluding: pending, noteHits: hits, noteHitsQuery: term)
        if revision == stateRevision, pending == pendingImportIDs {
            researchBriefMaintenance.verification = (brief.id, revision, pending, true)
        }
        guard isResearchBriefCurrent(brief) else {
            throw ReaderError.message("研究简报的来源刚刚更新，请重新读取。")
        }
        return brief
    }

    /// A tool loop can validate repeatedly without traversing an unchanged library. In-memory edits
    /// increment the revision immediately, even if a note is still waiting for its debounced save.
    func isResearchBriefCurrent(_ brief: ResearchBrief) -> Bool {
        if let cached = researchBriefMaintenance.verification, cached.briefID == brief.id,
            cached.revision == stateRevision, cached.pending == pendingImportIDs
        {
            return cached.valid
        }
        let valid = brief.isCurrent(in: state, excluding: pendingImportIDs)
        researchBriefMaintenance.verification = (brief.id, stateRevision, pendingImportIDs, valid)
        return valid
    }
}
