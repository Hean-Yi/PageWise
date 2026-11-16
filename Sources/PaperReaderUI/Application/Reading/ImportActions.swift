import Foundation
import PaperReaderKit

extension ReaderModel {
    @discardableResult public func importURLs(
        _ urls: [URL], selectAfterImport: Bool = true, metadata: PaperCandidate? = nil, shelfID: UUID? = nil,
        moveDuplicateToShelf: Bool = false,
        onlineDownload: DownloadedPublication? = nil
    ) async -> [UUID] {
        if let onlineDownload,
            urls.count != 1 || urls.first != onlineDownload.pdfURL || metadata?.id != onlineDownload.candidate.id
        {
            message = "线上资料与导入论文不匹配，未导入。"
            return []
        }
        if let metadata, ArxivClient.verified(metadata) == nil {
            message = "论文来源无效，未导入。"
            return []
        }
        guard loaded else {
            message = "书库尚未成功打开，不能导入以免覆盖已有资料。"
            return []
        }
        guard !isImporting else {
            message = "请等待当前导入完成。"
            return []
        }
        isImporting = true
        var importedIDs: [UUID] = []
        defer {
            isImporting = false
            importProgress = nil
        }
        for url in urls {
            do {
                status = "正在保存 \(url.lastPathComponent)…"
                importProgress = "准备导入"
                var imported = try await importer.storeOriginal(at: url)
                importProgress = "提交书库"
                let importedDirectory = root.appendingPathComponent(imported.originalPath).deletingLastPathComponent()
                var retained = false
                defer { if !retained { try? FileManager.default.removeItem(at: importedDirectory) } }
                try Task.checkCancellation()
                if let existing = state.papers.first(where: { $0.digest == imported.digest }) {
                    if let onlineDownload, existing.onlineSource?.archivePath == nil,
                        existing.sourceURL == nil || existing.sourceURL == onlineDownload.candidate.id,
                        existing.onlineSource == nil
                            || existing.onlineSource?.candidateID == onlineDownload.candidate.id
                    {
                        let attached = try await OnlineSourceStore().attach(onlineDownload, to: existing, root: root)
                        guard var latest = state.papers.first(where: { $0.id == existing.id }) else {
                            throw CancellationError()
                        }
                        latest.onlineSource = attached.onlineSource
                        latest.canReflow = true
                        latest.warnings = Array(Set(latest.warnings + attached.warnings)).sorted()
                        guard await save(cancellable: true, publishingReflow: latest) else {
                            if let path = attached.onlineSource?.archivePath {
                                try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
                            }
                            return importedIDs
                        }
                    }
                    if shelfID != nil || moveDuplicateToShelf {
                        guard await movePaper(existing.id, to: shelfID) else { return importedIDs }
                    }
                    // The unused duplicate directory is removed by the staging cleanup above.
                    if selectAfterImport { select(existing.id) }
                    importedIDs.append(existing.id)
                    status = "已打开书库中的相同论文"
                    continue
                }
                if let metadata {
                    imported.title = metadata.title
                    imported.sourceURL = metadata.id
                }
                if let onlineDownload {
                    imported = try await OnlineSourceStore().attach(onlineDownload, to: imported, root: root)
                }
                try Task.checkCancellation()
                pendingImportIDs.insert(imported.id)
                guard await save(cancellable: true, adding: imported, importShelfID: shelfID) else {
                    pendingImportIDs.remove(imported.id)
                    status = Task.isCancelled ? "已停止导入" : "导入未保存，请检查磁盘空间后重试"
                    return importedIDs
                }
                retained = true
                pendingImportIDs.remove(imported.id)
                importedIDs.append(imported.id)
                if selectAfterImport, !Task.isCancelled { select(imported.id) }
                status = imported.onlineSource == nil ? "已入库 · 阅读原版 PDF" : "已入库 · 可选择原版或 AI 双语重排"
            } catch is CancellationError {
                status = "已停止导入"
                return importedIDs
            } catch {
                message = "导入失败：\(error.localizedDescription)"
                status = "导入未完成"
            }
        }
        return importedIDs
    }

    public func addDemo() async {
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PaperReader-Demo-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("Understanding Attention.pdf")
            try DemoPaper.write(to: file)
            await importURLs([file])
        } catch { message = error.localizedDescription }
    }

    public func pauseTranslation() { if let id = selectedPaperID { translationTasks[id]?.cancel() } }
}
