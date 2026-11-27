import Foundation
import PaperReaderKit
import Testing

@Test func notebooksResolveEverySavedRunAgainstItsOwnPaperAndCurrentNote() throws {
    func paper(_ title: String) -> Paper {
        Paper(
            title: title, digest: title, originalPath: "sample.pdf", pageCount: 1, blocks: [], warnings: [],
            canReflow: false)
    }
    func summary(for paper: Paper) -> ReadingNote {
        var note = ReadingNote(paperID: paper.id, contentVersion: "v1", anchors: [], markdown: "最初的笔记")
        note.placement = .documentEnd
        return note
    }
    func run(_ paper: Paper, _ note: ReadingNote, _ time: TimeInterval) -> ChatTurn {
        var report = ChatTurn(paperID: paper.id, question: "实验", selection: "", answer: "分析范围", evidence: [])
        report.closeReadingVersion = "v1"
        report.readingNoteID = note.id
        report.createdAt = Date(timeIntervalSince1970: time)
        return report
    }
    let a = paper("A")
    let b = paper("B")
    var edited = summary(for: a)
    edited.markdown = "重新核对后写下的判断"
    var deleted = summary(for: a)
    deleted.deletedAt = Date()
    var paragraph = summary(for: a)
    paragraph.placement = nil
    let other = summary(for: b)
    var standalone = summary(for: a)
    standalone.createdAt = Date(timeIntervalSince1970: 0)
    let first = run(a, edited, 1)
    let repeated = run(a, edited, 3)
    let secondPaper = run(b, other, 2)
    var discussion = run(a, edited, 4)
    discussion.closeReadingVersion = nil
    var state = LibraryState()
    state.papers = [b, a]
    state.readingNotes = [edited, deleted, paragraph, other, standalone]
    state.chats = [
        repeated, run(b, edited, 5), first, discussion, secondPaper, run(a, deleted, 6), run(a, paragraph, 7),
    ]

    let notebooks = PaperReadingNotebook.notebooks(in: state)
    #expect(notebooks.map(\.id) == [a.id, b.id])
    let entries = try #require(notebooks.first?.entries)
    #expect(entries.map(\.id) == [repeated.id, first.id, standalone.id])
    #expect(entries.prefix(2).allSatisfy { $0.note.id == edited.id && $0.note.markdown == edited.markdown })
    #expect(entries.last?.date == standalone.createdAt && entries.last?.note == standalone)
    #expect(notebooks.last?.entries.map(\.id) == [secondPaper.id])
    state.readingNotes.removeAll { $0.id == edited.id }
    let remaining = PaperReadingNotebook.notebooks(in: state)
    #expect(remaining.map(\.id) == [b.id, a.id] && remaining.last?.entries.map(\.id) == [standalone.id])
}

@Test func notebookKeepsAnnotationOnlyRunsAndOmitsDeletedOrUnrelatedAnnotations() {
    let paper = Paper(
        title: "Fixture", digest: "fixture", originalPath: "fixture.pdf", pageCount: 1, blocks: [], warnings: [],
        canReflow: false)
    func note(_ text: String, paperID: UUID) -> ReadingNote {
        ReadingNote(paperID: paperID, contentVersion: "fixture", anchors: [], markdown: text)
    }
    let primary = note("核心批注", paperID: paper.id)
    let other = note("另一条批注", paperID: paper.id)
    var deleted = note("已删除", paperID: paper.id)
    deleted.deletedAt = Date()
    let unrelated = note("其他论文", paperID: UUID())
    var report = ChatTurn(paperID: paper.id, question: "AI 精读", selection: "", answer: "分析过的页数", evidence: [])
    report.closeReadingVersion = "fixture"
    report.closeReadingNoteIDs = [deleted.id, unrelated.id, primary.id, primary.id, other.id]
    var state = LibraryState()
    state.papers = [paper]
    state.readingNotes = [primary, other, deleted, unrelated]
    state.chats = [report]
    let entry = PaperReadingNotebook.notebooks(in: state).first?.entries.first
    #expect(entry?.id == report.id && entry?.note == primary)
    #expect(entry?.annotations == [other])
}

@Test func marginNoteGroupsSurfaceOfflinePassageNotesNotCoveredByCloseReading() {
    let paper = Paper(
        title: "Offline Paper", digest: "offline", originalPath: "offline.pdf", pageCount: 2, blocks: [],
        warnings: [], canReflow: false)
    let marginNote = ReadingNote(
        paperID: paper.id, contentVersion: "v1", anchors: [], markdown: "离线读到的关键反例。")
    var deletedNote = ReadingNote(
        paperID: paper.id, contentVersion: "v1", anchors: [], markdown: "已删除")
    deletedNote.deletedAt = Date()
    var state = LibraryState()
    state.papers = [paper]
    state.readingNotes = [marginNote, deletedNote]

    #expect(PaperReadingNotebook.notebooks(in: state).isEmpty)
    let groups = PaperReadingNotebook.marginNoteGroups(in: state)
    #expect(groups.count == 1)
    #expect(groups.first?.id == paper.id)
    #expect(groups.first?.notes == [marginNote])
}
