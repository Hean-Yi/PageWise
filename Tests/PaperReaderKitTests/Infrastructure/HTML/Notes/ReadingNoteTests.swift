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
    #expect(migrated.version == LibraryState.currentVersion)
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

@Test func assistantMarkdownRendersBlockStructureAndOnlyLinksRegisteredCitationsInProse() async throws {
    let renderer = NoteMarkdownRenderer()
    let source = #"""
        ## 比较

        > **结果** [S10] 和 [S1][S10]。[S99] [S2

        1. Inline \(a^2+b^2\)
        2. Price $5 and $10.

        \[
        \frac{1}{2}
        \]

        | x | y |
        | - | - |
        | $x$ | 2 |

        `\([S2]\)` and `$document$`

        \(\NotAKnownCommand{[S2]}\)

        ```swift
        "[S2]"
        ```

        [普通链接](https://example.org) <a href="paperreader-citation://foo" data-citation="S2">[S2]</a>
        <img src="https://example.org/a.png">
        """#
    let rendered = try await renderer.renderAssistant(source, citationIDs: ["S1", "S2", "S10"])
    #expect(rendered.citations == ["S10", "S1"])
    #expect(rendered.html.contains("<h2>"))
    #expect(rendered.html.contains("<blockquote>"))
    #expect(rendered.html.contains("<ol>"))
    #expect(rendered.html.contains("<table>"))
    #expect(rendered.html.contains("<pre>"))
    #expect(rendered.html.components(separatedBy: "<math").count == 4)
    #expect(rendered.html.contains("$5 and $10"))
    #expect(rendered.html.contains("普通链接"))
    #expect(!rendered.html.contains("example.org"))
    #expect(!rendered.html.contains("paperreader-citation"))
    #expect(rendered.html.components(separatedBy: #"data-citation="S10""#).count == 3)
    #expect(rendered.html.contains("[S99]"))
    #expect(rendered.html.contains(#"\(\NotAKnownCommand{[S2]}\)"#))
    #expect(!rendered.html.contains(#"data-citation="S2""#))
    let streamed = try await renderer.renderAssistant(source + "\n[S2]", citationIDs: ["S1", "S2", "S10"])
    #expect(streamed.citations == ["S10", "S1", "S2"])
    let otherTurn = try await renderer.renderAssistant(source)
    #expect(otherTurn.citations.isEmpty)
    #expect(!otherTurn.html.contains("href="))
}

@Test func readingNoteLinksAcceptOnlyRegisteredLocalDestinations() async throws {
    let id = UUID()
    let renderer = NoteMarkdownRenderer()
    let allowed = "paperreader://passage/" + id.uuidString
    let unknown = "paperreader://passage/" + UUID().uuidString
    let body = "[已登记](\(allowed)) [别的笔记](\(unknown)) [网页](https://example.org/) [文件](file:///tmp/demo)"
    let html = try await renderer.renderReadingNote(body, passageIDs: [id])
    #expect(html.contains("data-passage=\"\(id.uuidString)\""))
    #expect(html.contains(allowed))
    #expect(!html.contains(unknown) && !html.contains("https:") && !html.contains("file:"))
    #expect(html.contains("网页") && html.contains("文件"))
    let removed = try await renderer.renderReadingNote(body, passageIDs: [])
    #expect(!removed.contains("href="))
}
