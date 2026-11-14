import Foundation
import PaperReaderKit

extension ReaderModel {
    /// Explicitly retries old imports without replacing the original file or published layouts.
    public func reparseCurrentPaper(discovery: any PaperDiscovery = ArxivClient()) async {
        guard loaded, let original = paper, !isImporting,
            !translating.contains(original.id), original.htmlReading == nil,
            original.previewPages.isEmpty, original.translatedPages.isEmpty
        else { return }
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
                publication.htmlReading == nil, publication.translatedPages.isEmpty,
                publication.previewPages.isEmpty
            else { throw ReaderError.message("论文状态已变化，未替换已有内容。") }
            publication.blocks = parsed.blocks.map { block in
                var result = block
                let matches = original.blocks.filter { $0.sourcePage == block.sourcePage && $0.text == block.text }
                if matches.count == 1 { result.id = matches[0].id }
                return result
            }
            publication.canReflow = parsed.canReflow
            publication.warnings = parsed.warnings + (sourceWarning.map { [$0] } ?? [])
            publication.translations = [:]
            publication.translatedBlockCount = 0
            importProgress = PDFImportProgress(sequence: Int.max, stage: "保存解析结果")
            guard await save(cancellable: true, publishingReflow: publication) else { return }
            await loadNavigation()
            status = publication.canReflow ? "重新解析完成，可生成双语连续阅读" : "重新解析完成，当前仍需查看原版"
        } catch is CancellationError {
            status = "重新解析已停止，原有资料保留"
        } catch { message = "重新解析失败：\(error.localizedDescription)" }
    }
}
