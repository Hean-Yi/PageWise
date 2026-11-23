import Foundation
import PaperReaderKit

extension ReaderModel {
    var htmlAnnotationVersion: String? {
        guard usesHTMLReading, let paper else { return nil }
        return paper.htmlReading?.readingNoteVersion(digest: paper.digest)
    }

    var displayedHTMLHighlights: [Highlight] {
        guard let version = htmlAnnotationVersion else { return [] }
        return currentHighlights.filter {
            $0.textRange != nil && ($0.contentVersion == nil || $0.contentVersion == version)
        }
    }

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
        guard let version = htmlAnnotationVersion, let id = selectedPaperID, !htmlSelection.isEmpty,
            let colorName = value["color"] as? String, let color = AnnotationColor(rawValue: colorName),
            let styleName = value["style"] as? String, let style = AnnotationStyle(rawValue: styleName),
            let projections = value["legacy"] as? [[String: Any]], projections.count <= 10_000
        else { return }
        let projectedIDs = Set(projections.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
        let editions = currentEdition.map { [$0.htmlReading] + ($0.retainedReadings ?? []).map(\.html) } ?? []
        // Historical marks were shared by every edition containing the same section. Pin their copies
        // on first edit so erasing a legacy range in one edition preserves the others.
        var working = state.highlights.flatMap { mark -> [Highlight] in
            guard mark.paperID == id, mark.contentVersion == nil, let range = mark.textRange, range.count == 2,
                let digest = currentEdition?.digest
            else { return [mark] }
            let touched =
                projectedIDs.contains(mark.id)
                || htmlSelection.contains {
                    $0.pageKey == mark.pageKey && $0.target == mark.htmlTarget
                        && range[0] < ($0.highlightEnd ?? $0.end) && ($0.highlightStart ?? $0.start) < range[1]
                }
            guard touched else { return [mark] }
            let versions = Set(
                editions.compactMap { edition -> String? in
                    guard let edition, edition.sections.contains(where: { $0.id.uuidString == mark.pageKey }) else {
                        return nil
                    }
                    return edition.readingNoteVersion(digest: digest)
                })
            guard versions.contains(version) else { return [mark] }
            return versions.sorted().map { target in
                var copy = mark
                copy.contentVersion = target
                if target != version { copy.id = UUID() }
                return copy
            }
        }
        for projection in projections {
            guard let rawID = projection["id"] as? String, let oldID = UUID(uuidString: rawID),
                let old = working.first(where: {
                    $0.id == oldID && $0.paperID == id && $0.htmlTarget == nil && $0.contentVersion == version
                }),
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
            mark.contentVersion = version
            mark.htmlTarget = part.target
            mark.textRange = [start, end]
            return mark
        }
        guard !selections.isEmpty else { return }
        state.highlights = AnnotationRangeEditor.applying(
            selections, to: working, color: color, style: style, removing: value["remove"] as? Bool == true)
        highlightSaveTask = Task { await save() }
    }
}
