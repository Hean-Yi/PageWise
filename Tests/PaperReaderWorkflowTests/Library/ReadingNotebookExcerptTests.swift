import Testing

@testable import PaperReaderUI

@MainActor struct ReadingNotebookExcerptTests {
    @Test func indexUsesEditedProseAndKeepsInlineReferenceLabels() {
        let headings = "# 文末笔记\n\n[原文](paperreader://passage/fixture)\n\n## 一句话概括\n"
        #expect(ReadingNoteSummary.bodyExcerpt(headings) == "")
        #expect(
            ReadingNoteSummary.bodyExcerpt(headings + "**控制组**在[表 2](paperreader://passage/a)中仍有提升。")
                == "控制组在表 2中仍有提升。")
        #expect(ReadingNoteSummary.bodyExcerpt(headings + "控制组的提升只出现在第一个任务。") == "控制组的提升只出现在第一个任务。")
    }

    @Test func historyPreviewFindsProsePastFormattingAndBoundsLongNotes() {
        let markdown = "## 实验\n\n```swift\nlet x = 0\n```\n\n- 样本只覆盖了一种语言。"
        #expect(ReadingNoteSummary.bodyExcerpt(markdown) == "样本只覆盖了一种语言。")
        let long = ReadingNoteSummary.bodyExcerpt(String(repeating: "字", count: 5_000))
        #expect(long.count == 180 && long.last == "…")
    }

    @Test func olderCloseReadingFieldsLeadToTheirContentAndDoNotStripOrdinaryEmphasis() {
        let observation = "子组的变化方向相反，平均值会掩盖差异。"
        for prefix in ["**段落作用**\n\n", "**关键概念**\n\n", "**一句话概括：**", "**审读**　", "通俗解释: "] {
            #expect(ReadingNoteSummary.bodyExcerpt(prefix + observation) == observation)
        }
        #expect(ReadingNoteSummary.bodyExcerpt("**关键概念**之间存在重叠。") == "关键概念之间存在重叠。")
        #expect(ReadingNoteSummary.bodyExcerpt("**样本量**：仅有四例。") == "样本量：仅有四例。")
    }
}
