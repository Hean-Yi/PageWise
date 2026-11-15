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
                    current.htmlReading = nil
                    current.translatedPages = []
                    current.translations = [:]
                    current.translatedBlockCount = 0
                    current.blocks = []
                    current.canReflow = true
                    guard await self.save(publishingReflow: current) else { throw ReaderError.message("任务未能保存。") }
                }
                guard var current = self.state.papers.first(where: { $0.id == id }), let jobID = current.reflowJob?.id
                else { return }
                if current.reflowJob?.finished == true {
                    self.reflowStages[id] = "双语重排已完成"
                    return
                }
                if current.reflowJob?.sources.isEmpty == true {
                    let result = try await ReflowEvidenceExtractor().extract(paper: current, root: self.root) { stage in
                        Task { @MainActor [weak self] in
                            guard self?.state.papers.first(where: { $0.id == id })?.reflowJob?.id == jobID else {
                                return
                            }
                            self?.reflowStages[id] = stage
                        }
                    }
                    try Task.checkCancellation()
                    guard let fresh = self.state.papers.first(where: { $0.id == id }), fresh.reflowJob?.id == jobID
                    else { return }
                    current = fresh
                    current.reflowJob?.sources = result.blocks
                    current.warnings = result.warnings
                    guard !result.blocks.isEmpty else { throw ReaderError.message("未能识别可重排内容，请查看原版。") }
                    guard await self.save(publishingReflow: current) else { throw ReaderError.message("原文证据未能保存。") }
                }
                while let current = self.state.papers.first(where: { $0.id == id }), var job = current.reflowJob,
                    job.id == jobID
                {
                    try Task.checkCancellation()
                    let pending = job.sources.filter { !job.completedSourceIDs.contains($0.id) }
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
                    } else {
                        var chosen: [TextBlock] = []
                        var characters = 0
                        for source in pending {
                            if !chosen.isEmpty && (chosen.count >= 8 || characters + source.text.count > 6_000) {
                                break
                            }
                            chosen.append(source)
                            characters += source.text.count
                        }
                        window = chosen
                    }
                    self.reflowStages[id] = current.blocks.isEmpty ? "整理结构与生成首段内容" : "继续生成双语内容"
                    try await self.client.reflowAndTranslate(
                        sources: window, title: current.title, settings: settings, key: key,
                        acceptedPlan: job.acceptedPlan, committedPlanBlockIDs: job.committedBlockIDs,
                        onPlan: { [weak self] plan in
                            guard let self else { throw CancellationError() }
                            try await self.persistAIPlan(plan, paperID: id, jobID: jobID)
                        },
                        onDraft: { [weak self] block, text in
                            guard let self else { throw CancellationError() }
                            try await self.setAIDraft(block: block, text: text, paperID: id, jobID: jobID)
                        },
                        onBlock: { [weak self] pair, sourceIDs in
                            guard let self else { throw CancellationError() }
                            try await self.publishAIBlock(pair, sourceIDs: sourceIDs, paperID: id, jobID: jobID)
                        })
                    guard var publication = self.state.papers.first(where: { $0.id == id }),
                        publication.reflowJob?.id == jobID
                    else { return }
                    publication.reflowJob?.acceptedPlan = nil
                    publication.reflowJob?.committedBlockIDs = []
                    guard await self.save(publishingReflow: publication) else { throw ReaderError.message("窗口进度未能保存。") }
                }
            } catch {
                guard var publication = self.state.papers.first(where: { $0.id == id }) else { return }
                let reason = error is CancellationError ? "已暂停，可从已保存进度继续" : error.localizedDescription
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

    private func persistAIPlan(_ plan: AIReflowPlan, paperID: UUID, jobID: UUID) async throws {
        try Task.checkCancellation()
        guard var publication = state.papers.first(where: { $0.id == paperID }), publication.reflowJob?.id == jobID
        else { throw CancellationError() }
        publication.reflowJob?.acceptedPlan = plan
        publication.reflowJob?.failure = nil
        guard await save(publishingReflow: publication) else { throw ReaderError.message("分块计划未能保存，已停止。") }
    }

    private func setAIDraft(block: TextBlock, text: String, paperID: UUID, jobID: UUID) throws {
        try Task.checkCancellation()
        guard state.papers.first(where: { $0.id == paperID })?.reflowJob?.id == jobID else { throw CancellationError() }
        translationDraft = TranslationDraft(paperID: paperID, block: block, text: text)
    }

    private func publishAIBlock(_ pair: BilingualBlock, sourceIDs: [UUID], paperID: UUID, jobID: UUID) async throws {
        try Task.checkCancellation()
        guard let current = state.papers.first(where: { $0.id == paperID }), let job = current.reflowJob,
            job.id == jobID
        else { throw CancellationError() }
        guard !job.committedBlockIDs.contains(pair.block.id) else { return }
        guard Set(sourceIDs).isDisjoint(with: job.completedSourceIDs) else {
            throw ReaderError.message("来源内容重复，已停止发布。")
        }
        let artifact = try await HTMLReadingStore().append([pair], to: current.htmlReading, paper: current, root: root)
        try Task.checkCancellation()
        guard var publication = state.papers.first(where: { $0.id == paperID }), publication.reflowJob?.id == jobID
        else { throw CancellationError() }
        publication.htmlReading = artifact
        var savedBlock = pair.block
        if let translation = pair.translation {
            publication.translations[pair.block.id.uuidString] =
                pair.block.richContent?.readableTranslation(translation) ?? translation
        }
        savedBlock.richContent = nil
        publication.blocks.append(savedBlock)
        publication.translatedBlockCount = publication.blocks.count
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
        guard resourcesReady, bodyCount > 0, job.finished || bodyHeight >= max(200, viewportHeight * 1.5) else {
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
