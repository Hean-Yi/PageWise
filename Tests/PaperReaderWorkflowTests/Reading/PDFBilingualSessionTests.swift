import CoreGraphics
import CoreText
import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@Test @MainActor func pdfBilingualLayoutsKeepSavedChoicesAcrossWindowSizes() throws {
    let paragraph = try #require(PDFBilingualLayoutPreference(rawValue: "paragraph"))
    let automatic = try #require(PDFBilingualLayoutPreference(rawValue: "auto"))
    let split = try #require(PDFBilingualLayoutPreference(rawValue: "split"))
    let stacked = try #require(PDFBilingualLayoutPreference(rawValue: "stacked"))

    #expect(paragraph.resolved(at: 420) == .paragraph)
    #expect(paragraph.resolved(at: 1000) == .paragraph)
    #expect(automatic.resolved(at: 680) == .stacked)
    #expect(automatic.resolved(at: 1000) == .split)
    #expect(split.resolved(at: 420) == .stacked)
    #expect(split.resolved(at: 680) == .split)
    #expect(stacked.resolved(at: 1000) == .stacked)
}

@Test @MainActor func localPDFBilingualReadingRequiresExplicitTranslationAndReopensOffline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: file)
    let original = try Data(contentsOf: file)
    let transport = SentenceWorkflowTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    var settings = ModelSettings()
    settings.model = "offline-test"
    _ = try model.saveSettings(settings, key: "fixture-key")
    let paperID = try #require(await model.importURLs([file]).first)
    #expect(model.mode == "original")
    let session = model.pdfBilingual
    #expect(model.openBilingualReading(translatingDocument: false))
    try await waitForPageSession { !session.isLoading }
    #expect(await transport.requests == 0)
    let sentence = try #require(session.sentences.first)
    session.focusFromPDF(sentence.id)
    #expect(session.focusedID == sentence.id)
    session.translatePage(model)
    try await waitForPageSession { !session.isTranslating }
    #expect(session.error == nil)
    #expect(session.translations.count == session.sentences.count)
    let calls = await transport.requests
    #expect(calls > 0)
    model.captureSelection(text: "crosses pages", rects: [[10, 10, 40, 12]], page: 0, spansPages: true)
    session.translateSelection(model)
    #expect(!session.isTranslating)
    #expect(await transport.requests == calls)
    session.close()

    let reopened = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await reopened.load()
    reopened.select(paperID)
    reopened.pdfBilingual.open(reopened)
    try await waitForPageSession { !reopened.pdfBilingual.isLoading }
    #expect(reopened.pdfBilingual.translations == session.translations)
    #expect(await transport.requests == calls)
    let stored = try #require(reopened.paper?.originalPath)
    #expect(try Data(contentsOf: root.appendingPathComponent(stored)) == original)
}

@Test(arguments: [false, true]) @MainActor
func attachingOnlineMetadataStopsPDFTranslationAndUsesOnlySourceReflow(candidateOnly: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = SentenceWorkflowTransport()
    await transport.holdRequests(true)
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let url = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: url)
    let id = try #require(await model.importURLs([url]).first)
    var settings = ModelSettings()
    settings.model = "fixture"
    try model.saveSettings(settings, key: "fixture-key")
    #expect(model.openBilingualReading(translatingDocument: true))
    let oldJob = try #require(model.pdfDocumentTranslation.status(for: id))
    try await transport.waitForRequest()

    let candidate = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001v1", title: "Online fixture", authors: "", year: "",
        pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001v1")!)
    let download = DownloadedPublication(pdfURL: url, candidate: candidate, texArchive: nil)
    let ids = await model.importURLs(
        [url], selectAfterImport: false, metadata: candidate, onlineDownload: candidateOnly ? nil : download)
    #expect(ids == [id] && model.currentEdition?.usesSourceReflow == true)
    #expect(oldJob.phase == .paused && !model.pdfBilingual.isOpen)
    #expect(model.pdfDocumentTranslation.status(for: id) == nil)
    model.pdfBilingual.open(model, translatingDocument: true)
    model.captureSelection(text: "Sample passage", rects: [[0, 0, 20, 10]], page: 0)
    model.pdfBilingual.translateSelection(model)
    model.pdfDocumentTranslation.start(model, paperID: id, page: 0, resuming: true)
    model.setActive(false)
    model.setActive(true)
    await transport.holdRequests(false)
    #expect(!model.pdfBilingual.isOpen && model.pdfDocumentTranslation.status(for: id) == nil)
    #expect(await transport.requests == 1)
}

@Test @MainActor func paragraphTranslationPrioritizesTheOpenPageAndFinishesFromTheLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = SentenceWorkflowTransport()
    await transport.holdRequests(true)
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let file = root.appendingPathComponent("two-pages.pdf")
    try DemoPaper.write(to: file)
    let original = try Data(contentsOf: file)
    let paperID = try #require(await model.importURLs([file]).first)
    let paper = try #require(model.paper)
    var settings = ModelSettings()
    settings.model = "fixture"
    _ = try model.saveSettings(settings, key: "fixture-key")
    model.visiblePage = 1
    let session = model.pdfBilingual
    session.open(model, translatingDocument: true)
    let job = try #require(model.pdfDocumentTranslation.status(for: paperID))
    try await waitForPageSession { !session.isLoading && job.progress.activePageIndex == 1 }
    try await transport.waitForRequest()
    let firstSource = try #require(await transport.firstSource)
    #expect(session.paragraphSentences.contains { $0.text == firstSource })
    model.visiblePage = 0
    session.loadPage(model)
    session.setParagraphLayout(false, model: model)
    session.setParagraphLayout(true, model: model)
    model.setActive(false, suspendTranslation: false)
    model.select(nil)
    #expect(!session.isOpen && job.phase == .running)
    await transport.holdRequests(false)
    try await waitForPageSession { job.phase == .completed }
    #expect(job.progress.processedPages == paper.pageCount)
    let calls = await transport.requests

    // A new process with access to the same library, but no credential for the saved account.
    let reopened = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await reopened.load()
    reopened.select(paperID)
    reopened.pdfBilingual.open(reopened, translatingDocument: true)
    let offline = try #require(reopened.pdfDocumentTranslation.status(for: paperID))
    try await waitForPageSession { !reopened.pdfBilingual.isLoading && offline.phase == .completed }
    for page in 0..<paper.pageCount {
        reopened.visiblePage = page
        reopened.pdfBilingual.loadPage(reopened)
        try await waitForPageSession { !reopened.pdfBilingual.isLoading }
        let shown = reopened.pdfBilingual.paragraphSentences
        #expect(!shown.isEmpty && shown.allSatisfy { reopened.pdfBilingual.translations[$0.id] != nil })
    }
    #expect(await transport.requests == calls)
    #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == original)
}

@Test @MainActor func paragraphTranslationWaitsForSettingsAndResumesOnlySystemPauses() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = SentenceWorkflowTransport()
    await transport.holdRequests(true)
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let file = root.appendingPathComponent("settings.pdf")
    try DemoPaper.write(to: file)
    let id = try #require(await model.importURLs([file]).first)
    let session = model.pdfBilingual
    session.open(model, translatingDocument: true)
    guard case .needsConfiguration = model.pdfDocumentTranslation.status(for: id)?.phase else {
        Issue.record("缺少配置时应保留重排阅读并提供模型设置入口。")
        return
    }
    #expect(session.isOpen && session.error == nil)
    var settings = ModelSettings()
    settings.model = "fixture"
    _ = try model.saveSettings(settings, key: "fixture-key")
    let job = try #require(model.pdfDocumentTranslation.status(for: id))
    try await transport.waitForRequest()
    model.pdfDocumentTranslation.pause(id)
    model.setActive(false)
    model.setActive(true)
    session.setParagraphLayout(false, model: model)
    session.setParagraphLayout(true, model: model)
    #expect(job.phase == .paused)
    #expect(await transport.requests == 1)
    session.resumeDocumentTranslation(model)
    try await transport.waitForRequest(number: 2)
    model.setActive(false)
    #expect(job.phase == .paused)
    session.close()
    model.setActive(true)
    try await transport.waitForRequest(number: 3)
    #expect(job.phase == .running)
    await transport.holdRequests(false)
    try await waitForPageSession { job.phase == .completed }
}

@Test @MainActor func deniedDocumentWaitsForChangedConnectionOrExplicitRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = SentenceWorkflowTransport()
    await transport.respond(with: 401)
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let file = root.appendingPathComponent("access.pdf")
    try DemoPaper.write(to: file)
    let id = try #require(await model.importURLs([file]).first)
    var settings = ModelSettings()
    settings.model = "fixture"
    _ = try model.saveSettings(settings, key: "old-fixture-key")
    let session = model.pdfBilingual
    session.open(model, translatingDocument: true)
    let denied = try #require(model.pdfDocumentTranslation.status(for: id))
    try await waitForPageSession {
        if case .failed = denied.phase { return true }
        return false
    }
    session.close()
    session.open(model, translatingDocument: true)
    model.setActive(false)
    model.setActive(true)
    settings.temperature = 0.7
    _ = try model.saveSettings(settings, key: nil)
    let stillDenied = try #require(model.pdfDocumentTranslation.status(for: id))
    #expect(stillDenied.phase == denied.phase)
    #expect(await transport.requests == 1)

    await transport.respond(with: 200)
    _ = try model.saveSettings(settings, key: "replacement-fixture-key")
    let resumed = try #require(model.pdfDocumentTranslation.status(for: id))
    try await waitForPageSession { resumed.phase == .completed }
    #expect(await transport.requests > 1)
}

@Test @MainActor func cachedPageLoadPreservesNewerUpdatesAndRejectsOtherPaperUpdates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = SentenceWorkflowTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let file = root.appendingPathComponent("cached-page.pdf")
    try DemoPaper.write(to: file)
    let id = try #require(await model.importURLs([file]).first)
    var settings = ModelSettings()
    settings.model = "fixture"
    _ = try model.saveSettings(settings, key: "fixture-key")
    let session = model.pdfBilingual
    session.open(model)
    try await waitForPageSession { !session.isLoading }
    session.translatePage(model)
    try await waitForPageSession { !session.isTranslating }
    let sentence = try #require(session.paragraphSentences.first)
    #expect(session.translations[sentence.id] != nil)
    session.close()
    session.open(model)
    let fresh = [sentence.id: "较新的完整译句"]
    session.receiveDocumentTranslations(fresh, paperID: id, page: session.pageIndex)
    session.receiveDocumentTranslations(["foreign": "其他论文"], paperID: UUID(), page: session.pageIndex)
    session.receiveDocumentTranslations(["foreign": "其他页面"], paperID: id, page: session.pageIndex + 1)
    try await waitForPageSession { !session.isLoading }
    #expect(session.translations[sentence.id] == fresh[sentence.id])
    #expect(session.translations["foreign"] == nil)
}

@Test @MainActor func continuousParagraphReadingPrefetchesAndTracksPhysicalPagesWithoutNavigationFeedback() async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = SentenceWorkflowTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let file = root.appendingPathComponent("continuous.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(file as CFURL, mediaBox: &bounds, nil))
    let font = CTFontCreateWithName("Georgia" as CFString, 12, nil)
    for index in 0..<7 {
        context.beginPDFPage(nil)
        let text = NSAttributedString(
            string: "Readers can follow the source text on page \(index + 1).",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 60, y: 520)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
    }
    context.closePDF()
    let paperID = try #require(await model.importURLs([file]).first)
    model.navigateToPage(2)
    let session = model.pdfBilingual
    session.open(model)
    session.prepareParagraphReading(model)
    session.consumeParagraphJump(model)
    try await waitForPageSession { Set(session.paragraphPages.keys) == [1, 2, 3] }
    #expect(model.pdfDocumentTranslation.status(for: paperID) == nil)
    let revision = session.paragraphJumpRevision

    let neighboring = try #require(session.paragraphPages[3]?.sentences.first)
    session.receiveDocumentTranslations([neighboring.id: "相邻页保存的译句。"], paperID: paperID, page: 3)
    session.focusParagraphSentence(neighboring.id, model: model)
    #expect(model.visiblePage == 3 && session.pageIndex == 3 && !session.isLoading)
    #expect(session.focusedID == neighboring.id && session.translations[neighboring.id] == "相邻页保存的译句。")
    #expect(session.paragraphJumpRevision == revision && session.paragraphJumpPage == 3 && model.jumpPage == nil)
    #expect(model.workspace(for: paperID).position?.pageIndex == 3)
    session.followsScroll = false
    session.scrollFromParagraph(neighboring.id)
    #expect(session.pdfScrollID == neighboring.id)
    session.revealParagraphPage(3, model: model)
    #expect(session.pdfScrollID == nil && session.focusedID == nil)
    session.loadPage(model)
    #expect(session.paragraphJumpRevision == revision)

    model.navigateToPage(6)
    session.paragraphDidScroll(to: 2, model: model)
    #expect(model.visiblePage == 6)
    session.consumeParagraphJump(model)
    #expect(model.jumpPage == nil && session.paragraphJumpPage == 6)
    #expect(session.paragraphJumpRevision == revision + 1)
    try await waitForPageSession { Set(session.paragraphPages.keys) == [5, 6] }
    #expect(session.paragraphSentences.first?.pageIndex == 6)
    model.navigateToPage(6)
    session.consumeParagraphJump(model)
    #expect(session.paragraphJumpRevision == revision + 2)

    session.paragraphDidScroll(to: 0, model: model)
    session.paragraphDidScroll(to: 4, model: model)
    try await waitForPageSession { Set(session.paragraphPages.keys) == [3, 4, 5] }
    #expect(session.paragraphJumpRevision == revision + 2)
    session.setParagraphLayout(false, model: model)
    #expect(Set(session.paragraphPages.keys) == [4])
    session.close()
    #expect(session.paragraphPages.isEmpty)
    #expect(await transport.requests == 0)
}

@MainActor private func waitForPageSession(_ done: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !done() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(done())
}

private actor SentenceWorkflowTransport: HTTPTransport {
    private(set) var requests = 0
    private(set) var firstSource: String?
    private var holding = false
    private var responseCode = 200

    func holdRequests(_ hold: Bool) { holding = hold }
    func respond(with code: Int) { responseCode = code }

    func waitForRequest(number: Int = 1) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while requests < number, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(requests >= number)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let message = try #require((body?["messages"] as? [[String: String]])?.last?["content"])
        let input = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        let sentences = try #require(input?["sentences"] as? [[String: Any]])
        if firstSource == nil { firstSource = sentences.first?["en"] as? String }
        while holding { try await Task.sleep(for: .milliseconds(10)) }
        let pairs = try sentences.map { row in
            ["id": try #require(row["id"] as? String), "zh": "测试译句 " + (try #require(row["en"] as? String))]
        }
        let output = try JSONSerialization.data(withJSONObject: ["sentences": pairs])
        let choices: [[String: Any]] = [
            ["finish_reason": "stop", "message": ["content": String(decoding: output, as: UTF8.self)]]
        ]
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: responseCode, httpVersion: nil, headerFields: nil))
        return (try JSONSerialization.data(withJSONObject: ["choices": choices]), response)
    }
}
