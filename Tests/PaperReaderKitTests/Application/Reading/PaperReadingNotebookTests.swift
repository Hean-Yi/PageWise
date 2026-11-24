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
