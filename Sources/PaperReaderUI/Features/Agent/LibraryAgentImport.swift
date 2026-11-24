import Foundation
import PaperReaderKit

struct AgentImportRequest {
    let id: String
    let candidate: PaperCandidate
    /// Present only for a file the reader selected for this specific result.
    let selectedPDF: URL?
}

extension LibraryAgent {
    public func confirmImport(cardID: UUID) {
        enqueueImport(cardID: cardID, selectedPDF: nil)
    }

    func importPublisherPDF(_ url: URL, cardID: UUID) {
        guard url.isFileURL else { return }
        enqueueImport(cardID: cardID, selectedPDF: url)
    }

    func publisherFileSelectionFailed(_ error: Error, cardID: UUID) {
        guard let card = card(cardID), let id = card.candidateID,
            [.unprepared, .ready, .failed, .cancelled].contains(card.importState),
            !card.hasDownload || card.importState == .failed
        else { return }
        updateCandidateCards(id, state: .failed, error: Self.safeError(error, fallback: "无法读取所选文件，请重新选择 PDF。"))
    }

    func currentImportCard(_ original: AgentCard, candidate: PaperCandidate? = nil) -> AgentCard {
        guard let id = original.candidateID, let candidate = candidate ?? candidates[id] else { return original }
        if [.queued, .downloading, .importing].contains(original.importState) { return original }
        if original.importState == .imported, let paperID = original.paperID,
            reader.state.papers.contains(where: { $0.id == paperID })
        {
            return original
        }
        var card = original
        let imported = importedPapers[id].flatMap { saved in
            reader.state.papers.contains(where: { $0.id == saved }) ? saved : nil
        }
        // A newly available verified download can still add the matching source package.
        if let paperID = imported ?? reader.importedPaperID(for: candidate, includeUserLinked: !card.hasDownload) {
            card.paperID = paperID
            card.importState = .imported
            card.importError = nil
        } else if card.importState == .imported {
            card.paperID = nil
            card.importState = .unprepared
        }
        return card
    }

    private func enqueueImport(cardID: UUID, selectedPDF: URL?) {
        guard let card = card(cardID), card.kind == .onlineCandidate,
            let id = card.candidateID, let candidate = candidates[id]
        else { return }
        if selectedPDF == nil {
            guard card.hasDownload, candidate.canDownload else { return }
            if let paperID = card.paperID, card.importState == .imported {
                paperRegistry.insert(paperID)
                updateCandidateCards(id, state: .imported, paperID: paperID)
                _ = open(cardID: cardID)
                return
            }
        } else {
            guard !card.hasDownload || card.importState == .failed else { return }
        }
        guard importTasks[id] == nil, !queuedImports.contains(where: { $0.id == id }) else { return }
        let request = AgentImportRequest(id: id, candidate: candidate, selectedPDF: selectedPDF)
        guard importTasks.isEmpty else {
            queuedImports.append(request)
            updateCandidateCards(id, state: .queued)
            return
        }
        startImport(request)
    }

    private func startImport(_ request: AgentImportRequest) {
        let id = request.id
        let currentEpoch = epoch
        let currentSession = sessionID
        let token = UUID()
        importTokens[id] = token
        updateCandidateCards(id, state: request.selectedPDF == nil ? .downloading : .importing)
        importTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.importTokens[id] == token {
                    self.importTasks[id] = nil
                    self.importTokens[id] = nil
                    if !self.queuedImports.isEmpty {
                        self.startImport(self.queuedImports.removeFirst())
                    }
                }
            }
            do {
                let paperID = try await self.performImport(request, token: token, epoch: currentEpoch)
                // Once SQLite commits, cancellation cannot truthfully turn success into failure.
                guard self.sessionID == currentSession else { return }
                if request.selectedPDF == nil { self.importedPapers[id] = paperID }
                self.paperRegistry.insert(paperID)
                self.updateCandidateCards(id, state: .imported, paperID: paperID)
            } catch is CancellationError {} catch {
                guard self.epoch == currentEpoch, self.importTokens[id] == token, !Task.isCancelled else { return }
                self.updateCandidateCards(
                    id, state: .failed, error: Self.safeError(error, fallback: "论文导入未完成，请重试。"))
            }
        }
    }

    private func performImport(_ request: AgentImportRequest, token: UUID, epoch: UUID) async throws -> UUID {
        try checkImport(request.id, token: token, epoch: epoch)
        if let url = request.selectedPDF {
            while reader.isImporting { try await Task.sleep(for: .milliseconds(200)) }
            try checkImport(request.id, token: token, epoch: epoch)
            return try await reader.importPublisherPDF(url, for: request.candidate)
        }
        let download = try await discovery.downloadPublication(request.candidate)
        defer { try? FileManager.default.removeItem(at: download.pdfURL) }
        try checkImport(request.id, token: token, epoch: epoch)
        updateCandidateCards(request.id, state: .importing)
        while reader.isImporting { try await Task.sleep(for: .milliseconds(200)) }
        try checkImport(request.id, token: token, epoch: epoch)
        let paperIDs = await reader.importURLs(
            [download.pdfURL], selectAfterImport: false, metadata: download.candidate, onlineDownload: download)
        if let paperID = paperIDs.first { return paperID }
        try checkImport(request.id, token: token, epoch: epoch)
        throw ReaderError.message("论文导入未完成；请检查 PDF 或本地存储后重试。")
    }

    public func cancelImport(cardID: UUID) {
        guard let id = card(cardID)?.candidateID else { return }
        cancelCandidateImport(id)
    }

    func cancelCandidateImport(_ id: String) {
        if let index = queuedImports.firstIndex(where: { $0.id == id }) {
            queuedImports.remove(at: index)
            updateCandidateCards(id, state: .cancelled)
            return
        }
        guard let task = importTasks[id] else { return }
        // Retain the slot until cleanup finishes so a retry cannot race the previous commit.
        task.cancel()
        updateCandidateCards(id, state: .cancelled)
    }

    private func checkImport(_ id: String, token: UUID, epoch: UUID) throws {
        try check(epoch)
        guard importTokens[id] == token else { throw CancellationError() }
    }
}
