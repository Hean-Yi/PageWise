import Foundation

/// Replaces only selected ranges; the remainder keeps its original appearance and creation date.
public enum AnnotationRangeEditor {
    public static func applying(
        _ selections: [Highlight], to existing: [Highlight], color: AnnotationColor, style: AnnotationStyle,
        removing: Bool = false
    ) -> [Highlight] {
        var result = existing
        for selection in selections {
            guard let cut = selection.textRange, cut.count == 2, cut[0] < cut[1], selection.htmlTarget != nil else {
                continue
            }
            result = result.flatMap { mark -> [Highlight] in
                guard mark.paperID == selection.paperID, mark.pageKey == selection.pageKey,
                    mark.htmlTarget == selection.htmlTarget, let range = mark.textRange, range.count == 2,
                    range[0] < cut[1], cut[0] < range[1]
                else { return [mark] }
                guard range[0] >= 0, range[1] - range[0] == mark.text.utf16.count else { return [mark] }
                var remainder: [Highlight] = []
                for (start, end) in [(range[0], min(range[1], cut[0])), (max(range[0], cut[1]), range[1])]
                where start < end {
                    var fragment = mark
                    if !remainder.isEmpty { fragment.id = UUID() }
                    fragment.textRange = [start, end]
                    fragment.text = (mark.text as NSString).substring(
                        with: NSRange(location: start - range[0], length: end - start))
                    remainder.append(fragment)
                }
                return remainder
            }
            if !removing {
                var mark = selection
                mark.color = color
                mark.style = style
                result.append(mark)
            }
        }
        return result
    }
}
