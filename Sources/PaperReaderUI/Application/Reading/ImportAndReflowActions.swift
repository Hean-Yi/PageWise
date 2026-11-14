import Foundation
import PaperReaderKit

extension ReaderModel {
    @discardableResult public func importURLs(
        _ urls: [URL], selectAfterImport: Bool = true, metadata: PaperCandidate? = nil, shelfID: UUID? = nil,
        moveDuplicateToShelf: Bool = false, structuredBlocks: [TextBlock]? = nil
    ) async -> [UUID] {
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
            importProgressToken = nil
            importProgress = nil
        }
        for url in urls {
            do {
                status = "正在解析 \(url.lastPathComponent)…"
                let token = UUID()
                importProgressToken = token
                importProgress = PDFImportProgress(sequence: 0, stage: "准备导入")
                var imported = try await importer.importPDF(
                    at: url, preservingComplexPages: true, structuredBlocks: structuredBlocks
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.importProgressToken == token,
                            progress.sequence > (self.importProgress?.sequence ?? -1)
                        else { return }
                        self.importProgress = progress
                    }
                }
                importProgress = PDFImportProgress(sequence: Int.max, stage: "提交书库")
                let importedDirectory = root.appendingPathComponent(imported.originalPath).deletingLastPathComponent()
                var retained = false
                defer { if !retained { try? FileManager.default.removeItem(at: importedDirectory) } }
                try Task.checkCancellation()
                if let existing = state.papers.first(where: { $0.digest == imported.digest }) {
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
                if imported.canReflow {
                    imported.htmlReading = try await HTMLReadingStore().prepareOriginal(paper: imported, root: root)
                    for index in imported.blocks.indices { imported.blocks[index].richContent?.html = "" }
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
                status = imported.canReflow ? "已导入，可生成双语重排 · \(imported.blocks.count) 个段落" : "已导入 · 使用原始 PDF"
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

    public func startTranslation() {
        guard let paper, paper.canReflow, !translating.contains(paper.id) else { return }
        let id = paper.id
        translationPauseReason = nil
        translating.insert(id)
        translationTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.translating.remove(id)
                self.translationTasks[id] = nil
                if self.translationDraft?.paperID == id { self.translationDraft = nil }
            }
            do {
                let config = self.modelSettings
                let key = try await self.modelKey(for: config)
                guard !key.isEmpty, !config.model.isEmpty else {
                    throw ReaderError.message("请先打开设置，填写模型名称并保存 API Key。")
                }
                if var current = self.state.papers.first(where: { $0.id == id }), current.translatedPages.isEmpty,
                    current.htmlReading?.fullSource != true
                {
                    current.htmlReading = try await HTMLReadingStore().prepareOriginal(paper: current, root: self.root)
                    for index in current.blocks.indices { current.blocks[index].richContent?.html = "" }
                    guard await self.save(publishingReflow: current) else { throw ReaderError.message("原文未能保存，翻译已停止。") }
                    try HTMLReadingStore.cleanup(root: self.root, paper: current)
                }
                var lengthRetries = 0
                while let index = self.state.papers.firstIndex(where: { $0.id == id }) {
                    try Task.checkCancellation()
                    let current = self.state.papers[index]
                    let offset = current.translatedBlockCount
                    if offset >= current.blocks.count {
                        self.status =
                            current.blocks.contains { $0.preservesSourcePage == true }
                            ? "双语重排完成 · 复杂页面保留原版" : "全文翻译完成"
                        await self.retireUnusedPreview(for: id)
                        do { try await self.store.compact() } catch { self.status = "重排已完成，存储空间将在后续处理中回收。" }
                        break
                    }
                    let block = current.blocks[offset]
                    if block.richContent?.restoredTranslationHTML != nil {
                        try await self.publishTranslation(BilingualBlock(block: block, translation: nil), paperID: id)
                        continue
                    }
                    if block.preservesSourcePage == true || block.richContent?.requiresTranslation == false {
                        try await self.publishTranslation(BilingualBlock(block: block, translation: nil), paperID: id)
                        continue
                    }
                    if let cached = current.translations[block.id.uuidString] {
                        try block.richContent?.validate(cached)
                        try await self.publishTranslation(
                            BilingualBlock(block: block, translation: cached), paperID: id)
                        continue
                    }
                    var batch: [TextBlock] = []
                    var characters = 0
                    for candidate in current.blocks[offset...] {
                        let length = (candidate.richContent?.translationInput ?? candidate.text).count
                        if candidate.preservesSourcePage == true || candidate.richContent?.requiresTranslation == false
                            || current.translations[candidate.id.uuidString] != nil
                            || candidate.richContent?.restoredTranslationHTML != nil
                            || (!batch.isEmpty
                                && (batch.count >= (lengthRetries == 0 ? 6 : 2) || characters + length > 3_000))
                        {
                            break
                        }
                        batch.append(candidate)
                        characters += length
                    }
                    self.status = "正在流式翻译 \(offset + 1) / \(current.blocks.count)"
                    do {
                        try await self.client.translateParagraphs(
                            batch, title: current.title, settings: config, key: key,
                            maxOutputTokens: lengthRetries == 0 ? 8192 : 16384,
                            onDraft: { [weak self] block, text in
                                try Task.checkCancellation()
                                await self?.updateTranslationDraft(paperID: id, block: block, text: text)
                            },
                            onParagraph: { [weak self] block, translation in
                                guard let self else { throw CancellationError() }
                                try await self.publishTranslation(
                                    BilingualBlock(block: block, translation: translation), paperID: id)
                            })
                        lengthRetries = 0
                    } catch ModelStreamFailure.outputLimit {
                        guard lengthRetries < 2 else { throw ModelStreamFailure.outputLimit }
                        lengthRetries += 1
                        self.status = "模型输出达到上限，正在从已保存段落继续（\(lengthRetries)/2）"
                    }
                }
            } catch is CancellationError {
                self.translationPauseReason = self.translationPauseReason ?? "翻译已暂停，已完成段落已保存"
                self.status = self.translationPauseReason!
            } catch {
                if Task.isCancelled {
                    self.translationPauseReason = self.translationPauseReason ?? "翻译已暂停，已完成段落已保存"
                    self.status = self.translationPauseReason!
                } else {
                    self.message = error.localizedDescription
                    self.translationPauseReason = error.localizedDescription
                    self.status = "翻译暂停，可从已完成段落继续"
                }
            }
        }
    }

    private func updateTranslationDraft(paperID: UUID, block: TextBlock, text: String) {
        guard translating.contains(paperID) else { return }
        translationDraft = TranslationDraft(paperID: paperID, block: block, text: text)
        if selectedPaperID == paperID, paper?.htmlReading != nil, mode != "translated" { changeMode(to: "translated") }
    }

    private func publishTranslation(_ pair: BilingualBlock, paperID id: UUID) async throws {
        guard let current = state.papers.first(where: { $0.id == id }),
            current.blocks.indices.contains(current.translatedBlockCount),
            current.blocks[current.translatedBlockCount].id == pair.block.id
        else { throw ReaderError.message("翻译段落与当前进度不匹配，未发布。") }
        let offset = current.translatedBlockCount
        let end = offset + 1
        let pairs = [pair]
        try Task.checkCancellation()
        let useHTML = current.translatedPages.isEmpty
        let relative = "Papers/\(id.uuidString)/translated"
        let html: HTMLReadingArtifact?
        let rendered: [PageArtifact]
        if useHTML {
            html = try await HTMLReadingStore().append(
                pairs, to: current.htmlReading, paper: current, root: self.root)
            rendered = []
        } else {
            html = nil
            rendered = try await StructuredPageRenderer().render(
                pairs, to: self.root.appendingPathComponent(relative),
                originalURL: self.root.appendingPathComponent(current.originalPath))
        }
        var retained = false
        defer {
            if !retained {
                if useHTML, let fresh = self.state.papers.first(where: { $0.id == id }) {
                    try? HTMLReadingStore.cleanup(root: self.root, paper: fresh)
                }
                for page in rendered {
                    try? FileManager.default.removeItem(
                        at: self.root.appendingPathComponent(relative).appendingPathComponent(
                            page.relativePath))
                }
            }
        }
        try Task.checkCancellation()
        guard var publication = self.state.papers.first(where: { $0.id == id }) else { return }
        if let html { publication.htmlReading = html }
        if let translation = pair.translation { publication.translations[pair.block.id.uuidString] = translation }
        publication.translatedPages.append(
            contentsOf: rendered.map { page in
                var page = page
                page.relativePath = relative + "/" + page.relativePath
                return page
            })
        for blockIndex in offset..<end {
            let block = publication.blocks[blockIndex]
            if let rich = block.richContent, let translation = publication.translations[block.id.uuidString] {
                publication.translations[block.id.uuidString] = rich.readableTranslation(translation)
            }
            publication.blocks[blockIndex].richContent = nil
        }
        publication.translatedBlockCount = end
        guard await self.save(publishingReflow: publication) else {
            throw ReaderError.message("页面未能保存，翻译已停止；先前页面仍保留。")
        }
        retained = true
        if useHTML {
            do { try HTMLReadingStore.cleanup(root: self.root, paper: publication) } catch {
                self.status = "阅读内容已保存，临时文件将在下次打开时清理。"
            }
        }
        if self.selectedPaperID == id && self.mode != "translated" {
            self.changeMode(to: "translated")
        }
        if translationDraft?.paperID == id { translationDraft = nil }
        status = "已完成 \(end) / \(current.blocks.count) 段"
    }

    public func pauseTranslation() { if let id = selectedPaperID { translationTasks[id]?.cancel() } }

}
