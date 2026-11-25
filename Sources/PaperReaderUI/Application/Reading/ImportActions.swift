import Foundation
import PaperReaderKit

private enum PDFImportOrigin {
    case local
    case downloaded(DownloadedPublication)
    case selectedForPublication(PaperCandidate)

    var candidate: PaperCandidate? {
        switch self {
        case .local: nil
        case .downloaded(let download): download.candidate
        case .selectedForPublication(let candidate): candidate
        }
    }
}

private struct ImportSaveFailure: LocalizedError {
    let errorDescription: String?
}

struct PublicationAbstractFill {
    let paperID: UUID
    let candidateID: String
    let text: String

    func apply(to state: inout LibraryState) {
        guard let index = state.papers.firstIndex(where: { $0.id == paperID }),
            state.papers[index].onlineSource?.candidateID == candidateID,
            state.papers[index].onlineSource?.abstractText?.isEmpty != false
        else { return }
        state.papers[index].onlineSource?.abstractText = text
    }
}

extension ReaderModel {
    /// A downloadable result can require a verified source so a user-linked bibliography entry can still gain one.
    public func importedPaperID(
        for candidate: PaperCandidate, includeUserLinked: Bool = true,
        matching isInScope: (Paper) -> Bool = { _ in true }
    ) -> UUID? {
        guard let id = candidate.verified?.id else { return nil }
        if let downloaded = state.papers.first(where: {
            ($0.sourceURL == id || $0.onlineSource?.candidateID == id) && !pendingImportIDs.contains($0.id)
                && isInScope($0)
        }) {
            return downloaded.id
        }
        guard includeUserLinked else { return nil }
        return state.papers.first {
            $0.linkedPublicationURLs?.contains(id) == true && !pendingImportIDs.contains($0.id) && isInScope($0)
        }?.id
    }

    @discardableResult public func importPublisherPDF(
        _ url: URL, for candidate: PaperCandidate, shelfID: UUID? = nil, moveDuplicateToShelf: Bool = false,
        requestedAt: Date = .now
    ) async throws -> UUID {
        guard let candidate = candidate.verified else { throw ReaderError.message("论文来源无效，未导入。") }
        try beginPDFImport()
        defer { endPDFImport() }
        do {
            return try await importPDF(
                at: url, origin: .selectedForPublication(candidate), shelfID: shelfID,
                moveDuplicateToShelf: moveDuplicateToShelf, requestedAt: requestedAt)
        } catch {
            status = Task.isCancelled ? "已停止导入" : "导入未完成"
            throw error
        }
    }

    @discardableResult public func importURLs(
        _ urls: [URL], selectAfterImport: Bool = true, metadata: PaperCandidate? = nil, shelfID: UUID? = nil,
        moveDuplicateToShelf: Bool = false,
        onlineDownload: DownloadedPublication? = nil, requestedAt: Date = .now
    ) async -> [UUID] {
        // Earlier callers supplied the verified candidate and downloaded PDF without a TeX archive.
        let publication =
            onlineDownload
            ?? urls.first.flatMap { url in
                metadata.map { DownloadedPublication(pdfURL: url, candidate: $0) }
            }
        if let publication,
            urls.count != 1 || urls.first != publication.pdfURL || metadata?.id != publication.candidate.id
        {
            message = "线上资料与导入论文不匹配，未导入。"
            return []
        }
        if let metadata, !metadata.canDownload {
            message = "论文来源无效，未导入。"
            return []
        }
        do { try beginPDFImport() } catch {
            message = error.localizedDescription
            return []
        }
        defer { endPDFImport() }
        let origin = publication.map(PDFImportOrigin.downloaded) ?? .local
        var importedIDs: [UUID] = []
        for url in urls {
            do {
                let id = try await importPDF(
                    at: url, origin: origin, shelfID: shelfID, moveDuplicateToShelf: moveDuplicateToShelf,
                    requestedAt: requestedAt)
                importedIDs.append(id)
                if selectAfterImport, !Task.isCancelled { select(id) }
            } catch is CancellationError {
                status = "已停止导入"
                return importedIDs
            } catch is ImportSaveFailure {
                return importedIDs
            } catch {
                message = "导入失败：\(error.localizedDescription)"
                status = "导入未完成"
            }
        }
        return importedIDs
    }

    private func beginPDFImport() throws {
        guard loaded else { throw ReaderError.message("书库尚未成功打开，不能导入以免覆盖已有资料。") }
        guard !isImporting else { throw ReaderError.message("请等待当前导入完成。") }
        isImporting = true
    }

    private func endPDFImport() {
        isImporting = false
        importProgress = nil
    }

    private func importPDF(
        at url: URL, origin: PDFImportOrigin, shelfID: UUID?, moveDuplicateToShelf: Bool, requestedAt: Date
    ) async throws -> UUID {
        let id = try await commitPDF(
            at: url, origin: origin, shelfID: shelfID, moveDuplicateToShelf: moveDuplicateToShelf,
            requestedAt: requestedAt)
        importProgress = "整理摘要"
        await prepareImportedAbstract(for: id)
        guard state.papers.contains(where: { $0.id == id }) else {
            throw ReaderError.message("导入期间这篇论文已被删除。")
        }
        return id
    }

    private func commitPDF(
        at url: URL, origin: PDFImportOrigin, shelfID: UUID?, moveDuplicateToShelf: Bool, requestedAt: Date
    ) async throws -> UUID {
        status = "正在保存 \(url.lastPathComponent)…"
        importProgress = "准备导入"
        var imported = try await importer.storeOriginal(at: url)
        importProgress = "提交书库"
        let importedDirectory = root.appendingPathComponent(imported.originalPath).deletingLastPathComponent()
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: importedDirectory) } }
        try Task.checkCancellation()
        guard !wasPaperDeleted(since: requestedAt, digest: imported.digest, publicationID: origin.candidate?.id) else {
            throw ReaderError.message("导入期间这篇论文已被删除。")
        }
        if let existing = state.papers.first(where: { $0.digest == imported.digest }) {
            var attachment: Paper?
            var link: (paperID: UUID, url: String)?
            var abstract: PublicationAbstractFill?
            switch origin {
            case .downloaded(let publication) where shouldAttachSource(of: publication, toIdenticalPDF: existing):
                let attached = try await OnlineSourceStore().attach(publication, to: existing, root: root)
                guard var latest = state.papers.first(where: { $0.id == existing.id }) else {
                    throw CancellationError()
                }
                latest.onlineSource = attached.onlineSource
                latest.canReflow = attached.canReflow
                if existing.onlineSource?.originalPDFOnly == true, let oldNotice = existing.onlineSource?.notice {
                    latest.warnings.removeAll { $0 == oldNotice }
                }
                latest.warnings = Array(Set(latest.warnings + attached.warnings)).sorted()
                attachment = latest
            case .downloaded(let publication)
            where existing.onlineSource?.candidateID == publication.candidate.id
                && existing.onlineSource?.abstractText?.isEmpty != false:
                if let text = publication.candidate.abstractText, !text.isEmpty {
                    abstract = PublicationAbstractFill(
                        paperID: existing.id, candidateID: publication.candidate.id, text: text)
                }
            case .selectedForPublication(let candidate)
            where existing.linkedPublicationURLs?.contains(candidate.id) != true:
                link = (existing.id, candidate.id)
            default:
                break
            }
            let move: ShelfChange? =
                shelfID != nil || moveDuplicateToShelf ? .move(paperID: existing.id, shelfID: shelfID) : nil
            if move != nil || attachment != nil || link != nil || abstract != nil {
                let saved = await save(
                    cancellable: true, shelfChange: move, publishingReflow: attachment,
                    linkingPublication: link,
                    fillingSourceAbstract: abstract)
                if !saved, let path = attachment?.onlineSource?.archivePath {
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
                }
                try requireImportCommit(saved)
            }
            status = "论文已在书库中"
            return existing.id
        }
        imported.title = origin.candidate?.title ?? imported.title
        if let existing = LibraryQuery.paper(named: imported.title, in: state) {
            // The walkthrough always opens its bundled bytes, even if an unrelated PDF uses the example title.
            if case .local = origin, url == (try? DemoPaper.fileURL()) {
                let base = imported.title + "（内置示例）"
                imported.title = base
                var number = 2
                while LibraryQuery.paper(named: imported.title, in: state) != nil {
                    imported.title = base + " " + String(number)
                    number += 1
                }
            } else {
                let shelf = state.shelfID(for: existing.id).flatMap { id in state.shelves.first { $0.id == id }?.name }
                throw ReaderError.message("「\(shelf ?? "未分类论文")」已有同名论文《\(existing.title)》，已跳过这份不同的 PDF。")
            }
        }
        switch origin {
        case .selectedForPublication(let candidate):
            imported.linkedPublicationURLs = [candidate.id]
        case .downloaded(let publication):
            imported.sourceURL = publication.candidate.id
            imported = try await OnlineSourceStore().attach(publication, to: imported, root: root)
        case .local:
            break
        }
        try Task.checkCancellation()
        let id = imported.id
        pendingImportIDs.insert(id)
        defer { pendingImportIDs.remove(id) }
        try requireImportCommit(
            await save(
                cancellable: true, adding: imported, requestedAt: requestedAt, publicationID: origin.candidate?.id,
                importShelfID: shelfID))
        retained = true
        status = "已加入书库"
        return id
    }

    private func requireImportCommit(_ saved: Bool) throws {
        guard !saved else { return }
        try Task.checkCancellation()
        status = "导入未保存"
        throw ImportSaveFailure(errorDescription: message ?? status)
    }

    private func shouldAttachSource(of download: DownloadedPublication, toIdenticalPDF paper: Paper) -> Bool {
        guard paper.onlineSource?.archivePath == nil else { return false }
        let savedSource = paper.onlineSource?.candidateID ?? paper.sourceURL
        if savedSource == nil || savedSource == download.candidate.id { return true }
        return paper.onlineSource?.originalPDFOnly == true && download.candidate.source == .arxiv
            && ArxivClient.versionedIdentifier(download.candidate.id) != nil
    }

    @discardableResult public func openBundledSample() async -> UUID? {
        do {
            let ids = await importURLs([try DemoPaper.fileURL()])
            guard !Task.isCancelled else { return nil }
            return ids.first
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    public func pauseTranslation() { if let id = selectedPaperID { translationTasks[id]?.cancel() } }
}
