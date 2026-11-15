import Foundation
import PaperReaderKit

extension ReaderModel {
    func bookmarkHTMLSelection() {
        guard usesHTMLReading, let id = selectedPaperID, let first = htmlSelection.first,
            let index = pageKeys.firstIndex(of: first.pageKey)
        else { return }
        guard !currentBookmarks.contains(where: { $0.pageKey == first.pageKey }) else { return }
        state.bookmarks.append(PageBookmark(paperID: id, pageKey: first.pageKey, pageIndex: index, mode: mode))
        workspaceRevision += 1
        scheduleWorkspaceSave(immediately: true)
    }

    /// Only the isolated application script supplies validated projections of historical coordinates.
    func performHTMLAnnotation(_ value: [String: Any]) {
        guard usesHTMLReading, let id = selectedPaperID, !htmlSelection.isEmpty,
            let colorName = value["color"] as? String, let color = AnnotationColor(rawValue: colorName),
            let styleName = value["style"] as? String, let style = AnnotationStyle(rawValue: styleName),
            let projections = value["legacy"] as? [[String: Any]], projections.count <= 10_000
        else { return }
        var working = state.highlights
        for projection in projections {
            guard let rawID = projection["id"] as? String, let oldID = UUID(uuidString: rawID),
                let old = working.first(where: { $0.id == oldID && $0.paperID == id && $0.htmlTarget == nil }),
                let fragments = projection["parts"] as? [[String: Any]], !fragments.isEmpty, fragments.count <= 10_000
            else { return }
            var replacements: [Highlight] = []
            for fragment in fragments {
                guard let target = fragment["target"] as? String,
                    target == "source" || target == "translation"
                        || (target.hasPrefix("object:") && Int(target.dropFirst(7)).map { $0 >= 0 } == true),
                    let text = fragment["text"] as? String, let range = fragment["range"] as? [Int],
                    range.count == 2, range[0] >= 0, range[1] > range[0], range[1] <= 2_000_000,
                    range[1] - range[0] == text.utf16.count
                else { return }
                var mark = old
                if !replacements.isEmpty { mark.id = UUID() }
                mark.htmlTarget = target
                mark.linksTranslation = nil
                mark.text = text
                mark.textRange = range
                replacements.append(mark)
            }
            working.removeAll { $0.id == oldID }
            working.append(contentsOf: replacements)
        }
        let selections = htmlSelection.compactMap { part -> Highlight? in
            let start = part.highlightStart ?? part.start
            let end = part.highlightEnd ?? part.end
            guard let index = pageKeys.firstIndex(of: part.pageKey), start >= part.start, end <= part.end, end > start
            else { return nil }
            var mark = Highlight(
                paperID: id, pageKey: part.pageKey, pageIndex: index,
                text: (part.text as NSString).substring(
                    with: NSRange(location: start - part.start, length: end - start)), rects: [])
            mark.htmlTarget = part.target
            mark.textRange = [start, end]
            return mark
        }
        guard !selections.isEmpty else { return }
        state.highlights = AnnotationRangeEditor.applying(
            selections, to: working, color: color, style: style, removing: value["remove"] as? Bool == true)
        Task { await save() }
    }
}
