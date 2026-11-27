import Foundation
import Testing

@testable import PaperReaderKit

@Test func agentNoteRevisionKeepsTheReadersOriginalTextInHistory() {
    var note = ReadingNote(
        paperID: UUID(), contentVersion: "v", anchors: [], markdown: "Reader original wording.")
    let originalDate = note.modifiedAt
    let applied = note.applyAIRevision(
        "Updated wording with a new source.", at: originalDate.addingTimeInterval(60))
    #expect(applied)
    #expect(note.markdown == "Updated wording with a new source.")
    #expect(note.revisions?.count == 1)
    #expect(note.revisions?.first?.markdown == "Reader original wording.")
    #expect(note.revisions?.first?.author == .reader)
    let repeated = note.applyAIRevision(note.markdown)
    #expect(!repeated)
    #expect(note.revisions?.count == 1)
}

@Test func agentNoteRevisionDoesNotReviveADeletedNote() {
    var note = ReadingNote(paperID: UUID(), contentVersion: "v", anchors: [], markdown: "Deleted note.")
    note.deletedAt = Date()
    let applied = note.applyAIRevision("Should not appear.")
    #expect(!applied)
    #expect(note.markdown == "Deleted note.")
}

@Test func restoringNoteRevisionRestoresReaderTextAndKeepsAIHistory() throws {
    var note = ReadingNote(
        paperID: UUID(), contentVersion: "v", anchors: [], markdown: "读者原稿：先看等算力对照。")
    let applied = note.applyAIRevision("读者原稿：先看等算力对照。补充：见表 2。")
    #expect(applied)
    let readerRevision = try #require(note.revisions?.first)
    #expect(readerRevision.author == .reader)

    let restored = note.restoreRevision(readerRevision.id)
    #expect(restored)
    #expect(note.markdown == "读者原稿：先看等算力对照。")
    #expect(note.backgroundSources == nil)
    #expect(note.revisions?.count == 2)
    #expect(note.revisions?.last?.markdown == "读者原稿：先看等算力对照。补充：见表 2。")
}

@Test func fastModelSettingsFallsBackToPrimaryAndRoutesWhenConfigured() throws {
    var settings = ModelSettings()
    settings.baseURL = ModelServicePreset.openAI.baseURL
    settings.model = "gpt-5"
    #expect(try settings.normalized().fastSettings.model == "gpt-5")

    settings.fastModel = "  gpt-5-mini  "
    let normalized = try settings.normalized()
    #expect(normalized.fastModel == "gpt-5-mini")
    #expect(normalized.fastSettings.model == "gpt-5-mini")
    #expect(normalized.fastSettings.baseURL == normalized.baseURL)
}
