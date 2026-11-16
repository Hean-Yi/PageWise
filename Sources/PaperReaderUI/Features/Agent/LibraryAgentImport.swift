import Foundation
import PaperReaderKit

extension LibraryAgent {
    public func confirmImport(cardID: UUID) {
        guard let card = card(cardID), let id = card.candidateID, let candidate = candidates[id],
            ArxivClient.verified(candidate) != nil
        else { return }
        if let paperID = importedPapers[id], reader.state.papers.contains(where: { $0.id == paperID }) {
            paperRegistry.insert(paperID)
            updateCandidateCards(id, state: .imported, paperID: paperID)
            _ = open(cardID: cardID)
            return
        }
        guard importTasks[id] == nil else { return }
        guard !reader.isImporting, importTasks.isEmpty else {
            updateCandidateCards(id, state: .failed, error: "已有论文正在导入，请完成后重试。")
            return
        }
        let currentEpoch = epoch
        let currentSession = sessionID
        let token = UUID()
        importTokens[id] = token
        updateCandidateCards(id, state: .downloading)
        importTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.importTokens[id] == token {
                    self.importTasks[id] = nil
                    self.importTokens[id] = nil
                }
            }
            do {
                let download = try await self.discovery.downloadPublication(candidate)
                let url = download.pdfURL
                defer { try? FileManager.default.removeItem(at: url) }
                try Task.checkCancellation()
                try self.checkImport(id, token: token, epoch: currentEpoch)
                guard !self.reader.isImporting else { throw ReaderError.message("已有论文正在导入，请稍后重试。") }
                self.updateCandidateCards(id, state: .importing)
                let paperIDs = await self.reader.importURLs(
                    [url], selectAfterImport: false, metadata: download.candidate, onlineDownload: download)
                if let paperID = paperIDs.first {
                    // Once SQLite commits, cancellation cannot truthfully turn success into failure.
                    guard self.sessionID == currentSession else { return }
                    self.importedPapers[id] = paperID
                    self.paperRegistry.insert(paperID)
                    self.updateCandidateCards(id, state: .imported, paperID: paperID)
                } else {
                    try self.checkImport(id, token: token, epoch: currentEpoch)
                    throw ReaderError.message("论文导入未完成；请检查 PDF 或本地存储后重试。")
                }
            } catch is CancellationError {} catch {
                guard self.epoch == currentEpoch, self.importTokens[id] == token, !Task.isCancelled else { return }
                self.updateCandidateCards(
                    id, state: .failed, error: Self.safeError(error, fallback: "论文下载未完成，请重试或手动导入 PDF。"))
            }
        }
    }

    public func cancelImport(cardID: UUID) {
        guard let id = card(cardID)?.candidateID else { return }
        cancelCandidateImport(id)
    }

    func cancelCandidateImport(_ id: String) {
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
