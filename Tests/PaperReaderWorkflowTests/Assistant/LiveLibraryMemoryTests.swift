import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

/// Opt-in integration: copies the reader's library, runs the real configured model against a
/// bounded set of notes, and leaves the source library untouched.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_TEST_LIBRARY_NOTES"] == "1"))
@MainActor func liveModelSilentlyReviewsACopiedRealLibrary() async throws {
    let environment = ProcessInfo.processInfo.environment
    let source = try #require(environment["PAGEWISE_TEST_LIBRARY"])
    let key = try #require(environment["PAGEWISE_TEST_SLEEP_KEY"])
    let sourceRoot = URL(fileURLWithPath: source, isDirectory: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: sourceRoot.appendingPathComponent("library.sqlite"), to: root.appendingPathComponent("library.sqlite"))

    let credentials = WorkflowCredentials()
    let reader = try ReaderModel(root: root, credentials: credentials)
    await reader.load()
    let noteCount = reader.state.readingNotes.filter { $0.deletedAt == nil }.count
    #expect(noteCount > 0)
    var settings = ModelSettings()
    settings.baseURL = "https://api.deepseek.com"
    settings.model = "deepseek-flash"
    _ = try reader.saveSettings(settings, key: key)
    reader.noteReview.run(reader: reader, automatic: false, withModel: true)
    let deadline = ContinuousClock.now.advanced(by: .seconds(240))
    while reader.noteReview.running, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(250))
    }
    #expect(!reader.noteReview.running)
    #expect(reader.state.readingNotes.count == noteCount)
    let revised = reader.state.readingNotes.filter { $0.revisions?.isEmpty == false }
    for note in revised {
        #expect(note.revisions?.last?.markdown.isEmpty == false)
    }
    print("LIVE_LIBRARY_NOTES", noteCount, revised.count)
}
