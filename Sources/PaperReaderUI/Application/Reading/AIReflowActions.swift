import Foundation
import PaperReaderKit

extension ReaderModel {
    public func readOriginal() {
        readingChoicePresented = false
        mode = "original"
        visiblePage = 0
        jumpPage = 0
        beginReading()
    }

    public func openRetainedReading(_ id: UUID?) {
        endReading()
        retainedReadingID = id
        readingChoicePresented = false
        mode = "translated"
        visiblePage = 0
        jumpPage = 0
        beginReading()
    }

    public func startAIReflow(regenerate: Bool = false) {
        guard loaded, let selected = paper, !translating.contains(selected.id) else { return }
        let id = selected.id
        guard (try? modelSettings.normalized()) != nil else {
            message = "请先在模型设置中保存服务地址、模型和密钥。"
            return
        }
        endReading()
        readingChoicePresented = false
        retainedReadingID = nil
        translationPauseReason = nil
        reflowBodyCount = 0
        mode = "translated"
        translating.insert(id)
        reflowStartedAt[id] = Date()
        reflowStages[id] = "准备论文"
        translationTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.translating.remove(id)
                self.translationTasks[id] = nil
                if self.translationDraft?.paperID == id { self.translationDraft = nil }
            }
            do {
                let settings = self.modelSettings
                let key = try await self.modelKey(for: settings)
                guard !key.isEmpty else { throw ReaderError.message("请在模型设置中保存 API Key。") }
                guard var current = self.state.papers.first(where: { $0.id == id }) else { return }
                if current.reflowJob == nil || regenerate {
                    // Keep old artifacts available throughout preparation and publication.
                    if !current.readingPages.isEmpty {
                        var versions = current.retainedReadings ?? []
                        versions.append(RetainedReading(paper: current))
                        current.retainedReadings = versions
                    }
                    current.reflowJob = ReflowJob(sources: [])
                    current.reflowJob?.nextSourcePage = 0
                    current.htmlReading = nil
                    current.translatedPages = []
                    current.translations = [:]
                    current.translatedBlockCount = 0
                    current.blocks = []
                    current.warnings.removeAll { warning in
                        warning.hasPrefix("第 ")
                            && [
                                "保留原始版面", "OCR 未能可靠分离", "超过 OCR 局部图像预算", "本地 OCR 未完成",
                                "文字提取与 OCR 未能可靠分离",
                            ].contains(where: warning.contains)
                    }
                    current.canReflow = true
                    guard await self.save(publishingReflow: current) else { throw ReaderError.message("任务未能保存。") }
                }
                guard var current = self.state.papers.first(where: { $0.id == id }), let jobID = current.reflowJob?.id
                else { return }
                if current.reflowJob?.finished == true {
                    self.reflowStages[id] = "双语重排已完成"
                    return
                }
                if current.reflowJob?.modelSettings != settings {
                    // A new model may plan only the unpublished suffix. Committed source IDs and blocks stay intact.
                    current.reflowJob?.acceptedPlan = nil
                    current.reflowJob?.committedBlockIDs = []
                    current.reflowJob?.modelSettings = settings
                    guard await self.save(publishingReflow: current) else { throw ReaderError.message("模型配置未能保存。") }
                }
                if current.reflowJob?.failure != nil {
                    current.reflowJob?.failure = nil
                    guard await self.save(publishingReflow: current) else { throw ReaderError.message("恢复状态未能保存。") }
                }
                let extractor = ReflowEvidenceExtractor()
                var structureRetries = 0
                var usingRecovery = false
                var outputStalls = 0
                while let current = self.state.papers.first(where: { $0.id == id }), var job = current.reflowJob,
                    job.id == jobID
                {
                    try Task.checkCancellation()
                    guard self.modelSettings == settings else { throw CancellationError() }
                    if let plan = job.acceptedPlan, job.committedBlockIDs.count == plan.blocks.count {
                        var publication = current
                        structureRetries = 0
                        usingRecovery = false
                        publication.reflowJob?.acceptedPlan = nil
                        publication.reflowJob?.committedBlockIDs = []
                        guard await self.save(publishingReflow: publication) else {
                            throw ReaderError.message("窗口进度未能保存。")
                        }
                        continue
                    }
                    let pending = job.sources.filter { !job.completedSourceIDs.contains($0.id) }
                    let nextPage = job.nextSourcePage ?? (job.sources.isEmpty ? 0 : current.pageCount)
                    if pending.isEmpty, nextPage < current.pageCount {
                        let result = try await extractor.extractBatch(
                            paper: current, root: self.root, startingAt: nextPage
                        ) { stage in
                            Task { @MainActor [weak self] in
                                guard self?.state.papers.first(where: { $0.id == id })?.reflowJob?.id == jobID else {
                                    return
                                }
                                self?.reflowStages[id] = stage
                            }
                        }
                        try Task.checkCancellation()
                        guard self.modelSettings == settings,
                            var publication = self.state.papers.first(where: { $0.id == id }),
                            publication.reflowJob?.id == jobID
                        else { throw CancellationError() }
                        publication.reflowJob?.sources += result.blocks
                        publication.reflowJob?.nextSourcePage = result.nextPage
                        publication.warnings += result.warnings
                        guard await self.save(publishingReflow: publication) else {
                            throw ReaderError.message("原文证据与提取进度未能保存。")
                        }
                        continue
                    }
                    if pending.isEmpty {
                        var publication = current
                        job.finished = true
                        job.failure = current.translations.isEmpty ? "未识别到可翻译正文，请查看原版；已识别的图表和公式保留原文。" : nil
                        job.acceptedPlan = nil
                        job.committedBlockIDs = []
                        for index in job.sources.indices { job.sources[index].richContent = nil }
                        publication.reflowJob = job
                        guard await self.save(publishingReflow: publication) else {
                            throw ReaderError.message("完成状态未能保存。")
                        }
                        self.reflowStages[id] = job.failure ?? "双语重排已完成"
                        self.status = publication.warnings.isEmpty ? "双语重排完成" : "双语重排完成 · 部分区域保留原文"
                        break
                    }
                    let window: [TextBlock]
                    if let plan = job.acceptedPlan {
                        let ids = Set(plan.blocks.flatMap(\.sourceIDs))
                        window = job.sources.filter { ids.contains($0.id) }
                    } else if let group = pending.first?.reflowOrderGroup {
                        // Keep a page's unresolved order in one plan, including resume after a model change.
                        window = Array(pending.prefix { $0.reflowOrderGroup == group })
                    } else {
                        var chosen: [TextBlock] = []
                        var characters = 0
                        for source in pending {
                            if !chosen.isEmpty && (chosen.count >= 4 || characters + source.text.count > 2_400) {
                                break
                            }
                            chosen.append(source)
                            characters += source.text.count
                        }
                        window = chosen
                    }
                    self.reflowStages[id] = current.blocks.isEmpty ? "整理结构与生成首段内容" : "继续生成双语内容"
                    do {
                        if usingRecovery {
                            try await self.client.recoverReflowAndTranslate(
                                sources: window, title: current.title, settings: settings, key: key,
                                acceptedPlan: job.acceptedPlan, committedPlanBlockIDs: job.committedBlockIDs,
                                maxOutputTokens: min(32_768, 8192 << outputStalls),
                                onPlan: { [weak self] plan in
                                    guard let self else { throw CancellationError() }
                                    try await self.persistAIPlan(plan, paperID: id, jobID: jobID, settings: settings)
                                },
                                onDraft: { [weak self] block, text in
                                    guard let self else { throw CancellationError() }
                                    try await self.setAIDraft(
                                        block: block, text: text, paperID: id, jobID: jobID, settings: settings)
                                },
                                onBlock: { [weak self] pair, sourceIDs in
                                    guard let self else { throw CancellationError() }
                                    try await self.publishAIBlock(
                                        pair, sourceIDs: sourceIDs, paperID: id, jobID: jobID, settings: settings)
                                })
                        } else {
                            try await self.client.reflowAndTranslate(
                                sources: window, title: current.title, settings: settings, key: key,
                                acceptedPlan: job.acceptedPlan, committedPlanBlockIDs: job.committedBlockIDs,
                                maxOutputTokens: min(32_768, (job.acceptedPlan == nil ? 8192 : 4096) << outputStalls),
                                translationBlockLimit: outputStalls > 0 ? 1 : 2,
                                onPlan: { [weak self] plan in
                                    guard let self else { throw CancellationError() }
                                    try await self.persistAIPlan(plan, paperID: id, jobID: jobID, settings: settings)
                                },
                                onDraft: { [weak self] block, text in
                                    guard let self else { throw CancellationError() }
                                    try await self.setAIDraft(
                                        block: block, text: text, paperID: id, jobID: jobID, settings: settings)
                                },
                                onBlock: { [weak self] pair, sourceIDs in
                                    guard let self else { throw CancellationError() }
                                    try await self.publishAIBlock(
                                        pair, sourceIDs: sourceIDs, paperID: id, jobID: jobID, settings: settings)
                                })
                        }
                    } catch ModelStreamFailure.outputLimit {
                        try Task.checkCancellation()
                        guard self.modelSettings == settings,
                            let latest = self.state.papers.first(where: { $0.id == id })?.reflowJob,
                            latest.id == jobID
                        else { throw CancellationError() }
                        if latest.completedSourceIDs.count > job.completedSourceIDs.count {
                            outputStalls = 0
                        } else {
                            outputStalls += 1
                        }
                        guard outputStalls <= 2 else {
                            throw ReaderError.message("模型连续未能完成当前段落，已保留阅读位置与内容。请稍后继续或更换模型。")
                        }
                        if self.translationDraft?.paperID == id { self.translationDraft = nil }
                        self.reflowStages[id] = "继续生成双语内容"
                        continue
                    } catch AIReflowFailure.invalidStructure where structureRetries < 2 {
                        try Task.checkCancellation()
                        guard self.modelSettings == settings else { throw CancellationError() }
                        usingRecovery = true
                        let completed =
                            self.state.papers.first(where: { $0.id == id })?.reflowJob?.completedSourceIDs.count ?? 0
                        structureRetries = completed > job.completedSourceIDs.count ? 0 : structureRetries + 1
                        if self.translationDraft?.paperID == id { self.translationDraft = nil }
                        self.reflowStages[id] = "正在逐段生成，已完成内容可继续阅读"
                        continue
                    }
                    structureRetries = 0
                    outputStalls = 0
                    guard var publication = self.state.papers.first(where: { $0.id == id }),
                        publication.reflowJob?.id == jobID
                    else { return }
                    if let plan = publication.reflowJob?.acceptedPlan,
                        publication.reflowJob?.committedBlockIDs.count == plan.blocks.count
                    {
                        structureRetries = 0
                        usingRecovery = false
                        publication.reflowJob?.acceptedPlan = nil
                        publication.reflowJob?.committedBlockIDs = []
                        guard await self.save(publishingReflow: publication) else {
                            throw ReaderError.message("窗口进度未能保存。")
                        }
                    }
                }
            } catch {
                guard var publication = self.state.papers.first(where: { $0.id == id }) else { return }
                let cancelled =
                    error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled
                let reason = cancelled ? "已暂停，可从已保存进度继续" : error.localizedDescription
                publication.reflowJob?.failure = reason
                _ = await self.save(publishingReflow: publication)
                self.translationPauseReason = reason
                self.reflowStages[id] = reason
                self.status = reason
                if publication.reflowJob == nil {
                    self.mode = "original"
                    self.message = reason
                }
            }
        }
    }

    private func persistAIPlan(_ plan: AIReflowPlan, paperID: UUID, jobID: UUID, settings: ModelSettings) async throws {
        try Task.checkCancellation()
        guard modelSettings == settings else { throw CancellationError() }
        guard var publication = state.papers.first(where: { $0.id == paperID }), publication.reflowJob?.id == jobID
        else { throw CancellationError() }
        publication.reflowJob?.acceptedPlan = plan
        publication.reflowJob?.failure = nil
        guard await save(publishingReflow: publication) else { throw ReaderError.message("分块计划未能保存，已停止。") }
    }

    private func setAIDraft(block: TextBlock, text: String, paperID: UUID, jobID: UUID, settings: ModelSettings) throws
    {
        try Task.checkCancellation()
        guard modelSettings == settings else { throw CancellationError() }
        guard state.papers.first(where: { $0.id == paperID })?.reflowJob?.id == jobID else { throw CancellationError() }
        translationDraft = TranslationDraft(paperID: paperID, block: block, text: text)
    }

    private func publishAIBlock(
        _ pair: BilingualBlock, sourceIDs: [UUID], paperID: UUID, jobID: UUID, settings: ModelSettings
    ) async throws {
        try Task.checkCancellation()
        guard modelSettings == settings else { throw CancellationError() }
        guard let current = state.papers.first(where: { $0.id == paperID }), let job = current.reflowJob,
            job.id == jobID
        else { throw CancellationError() }
        guard !job.committedBlockIDs.contains(pair.block.id) else { return }
        guard Set(sourceIDs).isDisjoint(with: job.completedSourceIDs) else {
            throw ReaderError.message("来源内容重复，已停止发布。")
        }
        let excluded = pair.block.excludedFromReading == true
        let artifact: HTMLReadingArtifact?
        if excluded {
            artifact = current.htmlReading
        } else {
            artifact = try await HTMLReadingStore().append([pair], to: current.htmlReading, paper: current, root: root)
        }
        try Task.checkCancellation()
        guard modelSettings == settings else { throw CancellationError() }
        guard var publication = state.papers.first(where: { $0.id == paperID }), publication.reflowJob?.id == jobID
        else { throw CancellationError() }
        publication.htmlReading = artifact
        var savedBlock = pair.block
        if let translation = pair.translation {
            publication.translations[pair.block.id.uuidString] =
                pair.block.richContent?.readableTranslation(translation) ?? translation
        }
        savedBlock.richContent = nil
        if excluded {
            let excludedIDs = (publication.reflowJob?.excludedSourceIDs ?? []).union(sourceIDs)
            publication.reflowJob?.excludedSourceIDs = excludedIDs
        } else {
            publication.blocks.append(savedBlock)
        }
        publication.translatedBlockCount = publication.blocks.count
        publication.reflowJob?.failure = nil
        publication.reflowJob?.completedSourceIDs.formUnion(sourceIDs)
        publication.reflowJob?.committedBlockIDs.insert(pair.block.id)
        guard await save(publishingReflow: publication) else { throw ReaderError.message("双语内容未能保存，已暂停。") }
        if translationDraft?.paperID == paperID { translationDraft = nil }
        try? HTMLReadingStore.cleanup(root: root, paper: publication)
    }

    public func reportReflowReadiness(
        paperID: UUID, bodyCount: Int, bodyHeight: Double, viewportHeight: Double, resourcesReady: Bool
    ) {
        guard selectedPaperID == paperID, retainedReadingID == nil,
            let current = state.papers.first(where: { $0.id == paperID }),
            let job = current.reflowJob, !job.hasPresentedContent
        else { return }
        reflowBodyCount = bodyCount
        guard resourcesReady, bodyCount > 0, job.finished || bodyHeight >= min(240, max(120, viewportHeight * 0.4))
        else {
            return
        }
        presentReflowContent()
    }

    public func presentReflowContent() {
        guard let id = selectedPaperID, reflowBodyCount > 0, !reflowPresenting.contains(id) else { return }
        reflowPresenting.insert(id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.reflowPresenting.remove(id) }
            guard let jobID = self.state.papers.first(where: { $0.id == id })?.reflowJob?.id else { return }
            guard await self.save(presentingReflow: (paperID: id, jobID: jobID)) else { return }
            if self.selectedPaperID == id { self.beginReading() }
        }
    }
}
