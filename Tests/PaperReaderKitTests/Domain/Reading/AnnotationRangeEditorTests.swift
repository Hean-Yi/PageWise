import Foundation
import PaperReaderKit
import Testing

@Test func annotationEditsPreserveUnselectedFragmentsAndIndependentLanguages() throws {
    let paperID = UUID()
    func mark(_ text: String, _ start: Int, target: String = "source") -> Highlight {
        var result = Highlight(paperID: paperID, pageKey: "block", pageIndex: 0, text: text, rects: [])
        result.textRange = [start, start + text.utf16.count]
        result.htmlTarget = target
        return result
    }
    let old = mark("Alpha beta gamma delta", 0)
    let chinese = mark("对应译文", 0, target: "translation")
    let middle = mark("beta gamma", 6)
    let changed = AnnotationRangeEditor.applying([middle], to: [old, chinese], color: .blue, style: .underline)
    let source = changed.filter { $0.htmlTarget == "source" }.sorted { $0.textRange![0] < $1.textRange![0] }
    #expect(source.map(\.text) == ["Alpha ", "beta gamma", " delta"])
    #expect(source.map(\.color) == [nil, .blue, nil])
    #expect(source[0].createdAt == old.createdAt && source[2].createdAt == old.createdAt)
    #expect(changed.first { $0.htmlTarget == "translation" } == chinese)
    let mixed = mark("gamma delta epsilon", 11)
    let extended = AnnotationRangeEditor.applying([mixed], to: changed, color: .green, style: .highlight)
    let ranges = extended.filter { $0.htmlTarget == "source" }.sorted { $0.textRange![0] < $1.textRange![0] }
    #expect(ranges.map(\.text) == ["Alpha ", "beta ", "gamma delta epsilon"])
    #expect(ranges.map(\.color) == [nil, .blue, .green])
    let erased = AnnotationRangeEditor.applying(
        [mark("delta", 17)], to: extended, color: .green, style: .highlight, removing: true)
    #expect(
        erased.filter { $0.htmlTarget == "source" }.sorted { $0.textRange![0] < $1.textRange![0] }.map(\.text) == [
            "Alpha ", "beta ", "gamma ", " epsilon",
        ])
    #expect(Set(erased.map(\.id)).count == erased.count)
    let decoded = try JSONDecoder().decode([Highlight].self, from: JSONEncoder().encode(erased))
    #expect(decoded == erased)
    var legacy = old
    legacy.htmlTarget = nil
    let data = try JSONEncoder().encode(legacy)
    #expect(try JSONDecoder().decode(Highlight.self, from: data).color == nil)
}

@Test func translationInkEditsOnlyTheSelectedVersionAndTarget() {
    let id = UUID()
    func mark(_ text: String, start: Int, target: String, version: String) -> Highlight {
        var result = Highlight(paperID: id, pageKey: "original-1", pageIndex: 1, text: text, rects: [])
        result.pdfTranslationTarget = target
        result.contentVersion = version
        result.textRange = [start, start + text.utf16.count]
        return result
    }
    let full = mark("均值可能误导", start: 0, target: "translation-a", version: "v1")
    let old = mark("其他版本译文", start: 0, target: "translation-a", version: "v0")
    let other = mark("另一个段落", start: 0, target: "translation-b", version: "v1")
    let selected = mark("可能", start: 2, target: "translation-a", version: "v1")
    let updated = AnnotationRangeEditor.applying([selected], to: [old, other, full], color: .pink, style: .underline)
    #expect(Array(updated.prefix(2)) == [old, other])
    let parts = updated.dropFirst(2).sorted { $0.textRange![0] < $1.textRange![0] }
    #expect(parts.map(\.text) == ["均值", "可能", "误导"])
    #expect(parts.map(\.color) == [nil, .pink, nil])
}
