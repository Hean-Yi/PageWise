import Foundation
import PaperReaderKit

extension ReaderModel {
    /// Explicitly retries old imports without replacing the original file or published layouts.
    public func reparseCurrentPaper(
        discovery: any PaperDiscovery = ArxivClient(), replacingUnannotatedHTML: Bool = false
    ) async {
        guard loaded, let original = paper, !isImporting,
            !translating.contains(original.id), original.htmlReading == nil || replacingUnannotatedHTML,
            original.previewPages.isEmpty, original.translatedPages.isEmpty
        else { return }
        let keys = Set(original.readingPages.map { $0.id.uuidString })
        guard !state.highlights.contains(where: { $0.paperID == original.id && keys.contains($0.pageKey) }),
            !state.bookmarks.contains(where: { $0.paperID == original.id && keys.contains($0.pageKey) })
        else {
            message = "当前重排已有批注或书签，保留其版式，不能直接重新生成。"
            return
        }
        isImporting = true
        let token = UUID()
        importProgressToken = token
        importProgress = PDFImportProgress(sequence: 0, stage: "重新解析论文")
        defer {
            isImporting = false
            importProgressToken = nil
            importProgress = nil
        }
        do {
            let savedMarkup: [String: String]
            if let artifact = original.htmlReading {
                savedMarkup = try await HTMLReadingStore().translations(in: artifact, root: root)
            } else {
                savedMarkup = [:]
            }
            var structured: [TextBlock]?
            var sourceWarning: String?
            if let source = original.sourceURL, let url = URL(string: source), url.path.hasPrefix("/abs/"),
                let pdfURL = URL(string: "https://arxiv.org/pdf/" + url.path.dropFirst(5))
            {
                let candidate = PaperCandidate(
                    id: source, title: original.title, authors: "", year: "", pdfURL: pdfURL)
                importProgress = PDFImportProgress(sequence: 0, stage: "读取同版本 HTML")
                do { structured = try await discovery.structuredContent(candidate) } catch is CancellationError {
                    throw CancellationError()
                } catch { sourceWarning = "同版本 HTML 解析失败：\(error.localizedDescription)" }
            }
            let parsed = try await importer.importPDF(
                at: root.appendingPathComponent(original.originalPath), preservingComplexPages: true,
                structuredBlocks: structured
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.importProgressToken == token,
                        progress.sequence > (self.importProgress?.sequence ?? -1)
                    else { return }
                    self.importProgress = progress
                }
            }
            defer {
                try? FileManager.default.removeItem(
                    at: root.appendingPathComponent(parsed.originalPath).deletingLastPathComponent())
            }
            try Task.checkCancellation()
            guard parsed.digest == original.digest,
                var publication = state.papers.first(where: { $0.id == original.id }),
                publication.htmlReading == original.htmlReading, publication.translatedPages.isEmpty,
                publication.previewPages.isEmpty
            else { throw ReaderError.message("论文状态已变化，未替换已有内容。") }
            publication.blocks = parsed.blocks.enumerated().map { index, block in
                var result = block
                let matched = Self.previousBlock(at: index, in: parsed.blocks, previous: original.blocks)
                if let matched { result.id = matched.id }
                result.richContent?.restoredTranslationHTML =
                    savedMarkup[result.id.uuidString]
                    ?? matched?.richContent?.restoredTranslationHTML
                return result
            }
            publication.canReflow = parsed.canReflow
            publication.warnings = parsed.warnings + (sourceWarning.map { [$0] } ?? [])
            let currentIDs = Set(publication.blocks.map { $0.id.uuidString })
            publication.translations = original.translations.filter { currentIDs.contains($0.key) }
            publication.translatedBlockCount = 0
            publication.htmlReading = nil
            var ready: [BilingualBlock] = []
            for block in publication.blocks {
                if block.preservesSourcePage == true || block.richContent?.requiresTranslation == false {
                    ready.append(BilingualBlock(block: block, translation: nil))
                } else if let cached = original.translations[block.id.uuidString] {
                    if block.richContent?.restoredTranslationHTML != nil {
                        ready.append(BilingualBlock(block: block, translation: nil))
                    } else {
                        do { try block.richContent?.validate(cached) } catch { break }
                        ready.append(BilingualBlock(block: block, translation: cached))
                    }
                    publication.translations[block.id.uuidString] = cached
                } else {
                    break
                }
            }
            if original.htmlReading != nil {
                guard publication.canReflow, !ready.isEmpty else {
                    throw ReaderError.message("新解析尚不能替代已保存的阅读内容，原版式保留。")
                }
                publication.htmlReading = try await HTMLReadingStore().append(
                    ready, to: nil, paper: publication, root: root, restoringTranslationsFrom: original.htmlReading)
                publication.translatedBlockCount = ready.count
                for index in 0..<ready.count { publication.blocks[index].richContent = nil }
            }
            if publication.canReflow {
                publication.htmlReading = try await HTMLReadingStore().prepareOriginal(paper: publication, root: root)
                for index in publication.blocks.indices { publication.blocks[index].richContent?.html = "" }
            }
            defer {
                if let retained = state.papers.first(where: { $0.id == original.id }) {
                    try? HTMLReadingStore.cleanup(root: root, paper: retained)
                }
            }
            importProgress = PDFImportProgress(sequence: Int.max, stage: "保存解析结果")
            guard await save(cancellable: true, publishingReflow: publication) else { return }
            if selectedPaperID == original.id, publication.htmlReading != nil {
                mode = "translated"
                navigateToPage(0)
            }
            await loadNavigation()
            status = publication.canReflow ? "重新解析完成，可生成双语连续阅读" : "重新解析完成，当前仍需查看原版"
        } catch is CancellationError {
            status = "重新解析已停止，原有资料保留"
        } catch { message = "重新解析失败：\(error.localizedDescription)" }
    }
    static func previousBlock(at index: Int, in blocks: [TextBlock], previous: [TextBlock]) -> TextBlock? {
        let block = blocks[index]
        let old = previous.filter { $0.text == block.text && $0.preservesSourcePage == block.preservesSourcePage }
        if old.count == 1 { return old[0] }
        let samePage = old.filter { $0.sourcePage == block.sourcePage }
        if samePage.count == 1 { return samePage[0] }
        let current = blocks.indices.filter {
            blocks[$0].text == block.text && blocks[$0].preservesSourcePage == block.preservesSourcePage
        }
        guard old.count == current.count, let occurrence = current.firstIndex(of: index) else { return nil }
        return old[occurrence]
    }

}
