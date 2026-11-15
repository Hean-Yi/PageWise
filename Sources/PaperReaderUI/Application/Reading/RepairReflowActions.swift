import Foundation
import PaperReaderKit

extension ReaderModel {
    static func protectedReadingKeys(in state: LibraryState, paperID: UUID) -> Set<String> {
        Set(
            state.highlights.filter { $0.paperID == paperID }.map(\.pageKey)
                + state.bookmarks.filter { $0.paperID == paperID }.map(\.pageKey)
                + state.readingNotes.filter { $0.paperID == paperID }.flatMap { $0.anchors.map(\.key) })
    }

    public func startReflowRepair(paperIDs: [UUID]? = nil) {
        guard reflowRepairTask == nil, !isImporting else { return }
        isRepairingReflow = true
        reflowRepairTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.reflowRepairTask = nil
                self.isRepairingReflow = false
            }
            await self.repairLibraryReflow(paperIDs: paperIDs)
        }
    }

    public func cancelReflowRepair() { reflowRepairTask?.cancel() }

    public func repairLibraryReflow(paperIDs: [UUID]? = nil) async {
        guard loaded, !isImporting, translating.isEmpty else { return }
        isImporting = true
        defer {
            isImporting = false
            importProgress = nil
        }
        let ids = paperIDs ?? state.papers.map(\.id)
        var repaired = 0
        var failures = 0
        for (offset, id) in ids.enumerated() {
            guard let original = state.papers.first(where: { $0.id == id }) else { continue }
            importProgress = PDFImportProgress(
                sequence: offset, stage: "修复书库重排 · \(offset + 1)/\(ids.count)", completed: offset, total: ids.count)
            do {
                try Task.checkCancellation()
                defer {
                    if let retained = state.papers.first(where: { $0.id == id }) {
                        try? HTMLReadingStore.cleanup(root: root, paper: retained)
                    }
                }
                let result = try await HTMLReadingStore().repairPDFRegions(
                    paper: original, root: root, protectedKeys: Self.protectedReadingKeys(in: state, paperID: id),
                    discovery: ArxivClient())
                guard !result.changedKeys.isEmpty else { continue }
                guard
                    await save(
                        cancellable: true, publishingReflow: result.paper, repairBase: original,
                        changedReadingKeys: result.changedKeys)
                else {
                    failures += 1
                    continue
                }
                repaired += result.repairedPages
                if selectedPaperID == id { await loadNavigation() }
            } catch is CancellationError {
                status = "修复已停止，已保存的结果保留"
                return
            } catch {
                failures += 1
                message = "\(original.title)：\(error.localizedDescription)"
            }
        }
        let remaining = state.papers.reduce(0) {
            $0 + Set($1.blocks.filter { $0.preservesSourcePage == true }.map(\.sourcePage)).count
        }
        status = "已修复 \(repaired) 页；\(remaining) 页仍保留原版\(failures > 0 ? "，\(failures) 篇未更新" : "")"
    }
}
