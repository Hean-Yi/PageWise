import Foundation
import PaperReaderKit

extension ReaderModel {
    /// A legacy English preview may be retired only after the full bilingual result commits,
    /// and only when no user record or ink file depends on that layout.
    func retireUnusedPreview(for paperID: UUID) async {
        guard let index = state.papers.firstIndex(where: { $0.id == paperID }) else { return }
        let paper = state.papers[index]
        guard !paper.previewPages.isEmpty, !paper.readingPages.isEmpty,
            paper.translatedBlockCount == paper.blocks.count,
            !(selectedPaperID == paperID && mode == "reflow")
        else { return }
        let keys = Set(paper.previewPages.map { $0.id.uuidString })
        guard !state.highlights.contains(where: { $0.paperID == paperID && keys.contains($0.pageKey) }),
            !state.bookmarks.contains(where: { $0.paperID == paperID && keys.contains($0.pageKey) })
        else { return }
        let ink = root.appendingPathComponent("Papers/\(paperID.uuidString)/Ink")
        for key in keys {
            for ext in ["drawing", "png"]
            where FileManager.default.fileExists(
                atPath: ink.appendingPathComponent(key).appendingPathExtension(ext).path)
            { return }
        }
        let prefix = "Papers/\(paperID.uuidString)/preview/"
        guard
            paper.previewPages.allSatisfy({
                $0.relativePath.hasPrefix(prefix) && !$0.relativePath.dropFirst(prefix.count).contains("/")
            })
        else { return }
        let oldWorkspace = state.workspace[paperID.uuidString]
        if let position = oldWorkspace?.position, keys.contains(position.pageKey) {
            let sourcePage = PaperPageLocator.sourcePage(for: position, in: paper) ?? 0
            state.workspace[paperID.uuidString]?.position =
                PaperPageLocator.position(sourcePage: sourcePage, mode: "translated", in: paper)
                ?? PaperPageLocator.position(sourcePage: sourcePage, mode: "original", in: paper)
        }
        state.papers[index].previewPages = []
        guard await save() else {
            if let fresh = state.papers.firstIndex(where: { $0.id == paperID }) {
                state.papers[fresh].previewPages = paper.previewPages
            }
            state.workspace[paperID.uuidString] = oldWorkspace
            return
        }
        for page in paper.previewPages {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(page.relativePath))
        }
        let folder = root.appendingPathComponent(prefix)
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
