import Foundation
import Testing

@testable import PaperReaderKit

private func exportPaper(_ title: String) -> Paper {
    Paper(
        title: title, digest: title, originalPath: "source.pdf", pageCount: 2, blocks: [], warnings: [],
        canReflow: false)
}

private func exportNote(_ text: String, paper: Paper, quote: String? = nil) -> ReadingNote {
    let anchors =
        quote.map { [NoteAnchor(key: "original-1", target: "pdf", text: $0, start: 0, end: $0.utf16.count)] } ?? []
    var note = ReadingNote(
        paperID: paper.id, contentVersion: paper.digest + ":original-0", anchors: anchors, markdown: text)
    if quote == nil { note.placement = .documentEnd }
    return note
}

private func exportRun(_ paper: Paper, summary: ReadingNote?, annotations: [ReadingNote], coverage: String) -> ChatTurn
{
    var turn = ChatTurn(paperID: paper.id, question: "核查实验", selection: "", answer: coverage, evidence: [])
    turn.closeReadingVersion = paper.digest + ":original-0"
    turn.readingNoteID = summary?.id
    turn.closeReadingNoteIDs = annotations.map(\.id)
    return turn
}

@Test func obsidianReadingDocumentExportsEveryLiveNoteAndTheOriginalCoverageOnce() throws {
    let paper = exportPaper("Averages")
    let other = exportPaper("Private paper")
    let summary = exportNote("## 调整后怎样？\n\n手工修订了 **对照条件**。", paper: paper)
    let history = exportNote("此前的综合判断。", paper: paper)
    var annotation = exportNote("这两个样本规模不同。", paper: paper, quote: "The cohorts differ in size.")
    annotation.dimension = .evidence
    let manual = exportNote("我的追问。", paper: paper, quote: "A smaller cohort.")
    var deleted = exportNote("已经丢弃的批注。", paper: paper, quote: "Deleted quote.")
    deleted.deletedAt = Date()
    let otherNote = exportNote("他篇私人意见。", paper: other)
    var state = LibraryState()
    state.papers = [paper, other]
    state.chats = [
        exportRun(paper, summary: history, annotations: [annotation], coverage: "此前覆盖一页"),
        exportRun(paper, summary: summary, annotations: [annotation, deleted, annotation], coverage: "核查两页 · 一节未能核对"),
        exportRun(other, summary: otherNote, annotations: [], coverage: "其他覆盖"),
    ]
    state.readingNotes = [history, summary, annotation, manual, deleted, otherNote]
    state.highlights = [
        Highlight(paperID: paper.id, pageKey: "original-1", pageIndex: 1, text: annotation.anchors[0].text, rects: []),
        Highlight(paperID: paper.id, pageKey: "original-0", pageIndex: 0, text: "Additional mark.", rects: []),
    ]
    let exported = try ObsidianReadingDocument.markdown(paper: paper, in: state)
    for text in [
        summary.markdown, history.markdown, annotation.markdown, manual.markdown, "Additional mark.",
        "核查两页 · 一节未能核对", "此前覆盖一页", annotation.anchors[0].text,
    ] {
        #expect(exported.components(separatedBy: text).count == 2)
    }
    #expect(exported.range(of: summary.markdown)!.lowerBound < exported.range(of: history.markdown)!.lowerBound)
    #expect(exported.contains("实证证据与数据"))
    #expect(exported.contains("原文第 2 页"))
    #expect(!exported.contains(deleted.markdown))
    #expect(!exported.contains(otherNote.markdown))
    #expect(!exported.contains("其他覆盖"))
    #expect(try ObsidianReadingDocument.markdown(paper: paper, in: state) == exported)
}

@Test func obsidianReadingDocumentMakesRegisteredSourcesReadableAndRespectsEditedReferences() throws {
    let paper = exportPaper("Controls")
    let source = exportPaper("Calibration")
    let excerpt = "Measured twice."
    let oldObservation = "未排除温度影响。"
    let otherNote = exportNote(oldObservation + " 其余观察未被引用。", paper: source, quote: "Temperature")
    let passage = LocalPassageCitation(
        paperID: paper.id, digest: paper.digest, contentVersion: paper.digest + ":original-0",
        anchors: exportNote("", paper: paper, quote: excerpt).anchors, quote: excerpt)
    let memory = LocalPassageCitation(note: otherNote, digest: source.digest, quote: oldObservation)
    let reference = passage.markdown(label: "测量步骤")
    let memoryLink = memory.markdown(label: oldObservation)
    var summary = exportNote("计算 $a+b$。\n\n" + reference + "\n\n" + memoryLink + "\n\n再次核对 " + reference, paper: paper)
    summary.citations = [passage, memory]
    var state = LibraryState()
    state.papers = [paper, source]
    state.chats = [exportRun(paper, summary: summary, annotations: [], coverage: "已核对")]
    state.readingNotes = [summary, otherNote]
    let result = try ObsidianReadingDocument.markdown(paper: paper, in: state)
    #expect(result.components(separatedBy: excerpt).count == 2)
    #expect(result.contains("测量步骤[^pr-1]"))
    #expect(result.contains("[^pr-1]: 原文第 2 页"))
    #expect(result.contains("《Calibration》 · 阅读笔记"))
    #expect(result.contains(oldObservation))
    #expect(!result.contains("其余观察未被引用"))
    #expect(!result.contains("paperreader://"))
    #expect(result.contains("$a+b$"))
    for delete in [false, true] {
        if delete { state.readingNotes[1].deletedAt = Date() } else { state.readingNotes[1].markdown = "已重新核对，温度一致。" }
        let updated = try ObsidianReadingDocument.markdown(paper: paper, in: state)
        #expect(!updated.contains(oldObservation))
        #expect(updated.contains("所引笔记已修改或删除"))
    }
}

@Test func obsidianReadingDocumentKeepsAnnotationOnlyRunsAndRejectsBrokenMembership() throws {
    let paper = exportPaper("Methods")
    let other = exportPaper("Other")
    let note = exportNote("没有产生综合时仍保留这条批注。", paper: paper, quote: "One observation.")
    let foreign = exportNote("只属于另一本。", paper: other)
    var state = LibraryState()
    state.papers = [paper, other]
    state.chats = [exportRun(paper, summary: nil, annotations: [note], coverage: "综合未完成")]
    state.readingNotes = [note, foreign]
    #expect(try ObsidianReadingDocument.markdown(paper: paper, in: state).contains(note.markdown))
    for invalid in [foreign.id, UUID()] {
        state.chats[0].closeReadingNoteIDs = [note.id, invalid]
        #expect(throws: ReaderError.self) { try ObsidianReadingDocument.markdown(paper: paper, in: state) }
    }
}

@Test func obsidianReadingDocumentResolvesSourceSectionsInTheNoteEditionAndLeavesCodeLiteral() throws {
    var paper = exportPaper("Retained source")
    let shared = PageArtifact(blockIDs: [], sourcePage: -1, relativePath: "old.html")
    let earlier = PageArtifact(blockIDs: [], sourcePage: -1, relativePath: "other.html")
    paper.htmlReading = HTMLReadingArtifact(relativePath: "old.html", sections: [earlier, shared], assets: [])
    let version = try #require(paper.htmlReading?.readingNoteVersion(digest: paper.digest))
    paper.retainedReadings = [RetainedReading(paper: paper)]
    paper.htmlReading = HTMLReadingArtifact(relativePath: "new.html", sections: [shared], assets: [])
    let anchor = NoteAnchor(key: shared.id.uuidString, target: "source", text: "Source excerpt.", start: 0, end: 15)
    let ref = LocalPassageCitation(
        paperID: paper.id, digest: paper.digest, contentVersion: version, anchors: [anchor], quote: anchor.text)
    let link = ref.markdown(label: "参见")
    var note = ReadingNote(
        paperID: paper.id, contentVersion: version, anchors: [anchor],
        markdown: "\(link)\n\n代码示例：`\(link)`。")
    note.citations = [ref]
    var state = LibraryState()
    state.papers = [paper]
    state.readingNotes = [note]
    let rendered = try ObsidianReadingDocument.markdown(paper: paper, in: state)
    #expect(rendered.contains("源码第 2 段"))
    #expect(!rendered.contains("源码第 1 段"))
    #expect(rendered.contains("参见[^pr-1]"))
    #expect(rendered.contains("`\(link)`"))
}
