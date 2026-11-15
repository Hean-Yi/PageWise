import Foundation
import Testing

@testable import PaperReaderKit

@Test func readingNotesMigrateFromV6WithoutChangingAnnotationsAndRoundtrip() throws {
    var state = LibraryState()
    let note = ReadingNote(
        paperID: UUID(), contentVersion: "stable",
        anchors: [NoteAnchor(key: "a", target: "translation", text: "中文", start: 1, end: 3)], markdown: "**想法** $x^2$")
    state.readingNotes = [note]
    var highlight = Highlight(paperID: note.paperID, pageKey: "a", pageIndex: 0, text: "中文", rects: [])
    highlight.textRange = [1, 3]
    highlight.htmlTarget = "translation"
    highlight.style = .underline
    highlight.color = .blue
    state.highlights = [highlight]
    let roundtrip = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
    #expect(roundtrip.readingNotes == [note])
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    legacy["version"] = 6
    legacy.removeValue(forKey: "readingNotes")
    let migrated = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(migrated.version == 7)
    #expect(migrated.readingNotes.isEmpty)
    #expect(migrated.highlights == state.highlights)
}

@Test func noteMarkdownRendersMathTablesTasksAndPreservesBrokenSourceSafely() async throws {
    let renderer = NoteMarkdownRenderer()
    let html = try await renderer.render(
        #"""
        # 想法
        **加粗** 和 $x^2+\alpha$。

        $$
        \sum_{i=1}^{n} i
        $$

        - [x] 完成
        - 下一步

        | A | B |
        | --- | --- |
        | 1 | 2 |

        `$not_math$`

        ```tex
        $code_only$
        ```

        $\unknowncommand{x}$

        <script>alert(1)</script><img src="https://example.com/tracker" onerror="alert(1)">
        [bad](javascript:alert%281%29)
        [good](https://example.com/)
        """#)
    #expect(html.contains("<h1>"))
    #expect(html.contains("<strong>加粗</strong>"))
    #expect(html.contains("<table>"))
    #expect(html.contains("checkbox"))
    #expect(html.components(separatedBy: "<math").count == 3)
    #expect(html.contains("display=\"block\""))
    #expect(html.contains("$not_math$"))
    #expect(html.contains("$code_only$"))
    #expect(html.contains("note-math-error"))
    #expect(html.contains(#"\unknowncommand"#))
    #expect(!html.contains("<script"))
    #expect(!html.contains("<img"))
    #expect(!html.contains("javascript:"))
    #expect(html.contains("https://example.com/"))
    let incomplete = try await renderer.render("尚未完成 $x +")
    #expect(incomplete.contains("$x +"))
}
