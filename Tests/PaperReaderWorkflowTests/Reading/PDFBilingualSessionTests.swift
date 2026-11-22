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
    session.open(model)
    try await waitForPageSession { !session.isLoading }
    #expect(await transport.requests == 0)
    let sentence = try #require(session.sentences.first)
    session.focusFromPDF(sentence.id)
    #expect(session.activeID == sentence.id)
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

@MainActor private func waitForPageSession(_ done: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !done() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(done())
}

private actor SentenceWorkflowTransport: HTTPTransport {
    private(set) var requests = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let message = try #require((body?["messages"] as? [[String: String]])?.last?["content"])
        let input = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        let sentences = try #require(input?["sentences"] as? [[String: Any]])
        let pairs = try sentences.map { row in
            ["id": try #require(row["id"] as? String), "zh": "测试译句 " + (try #require(row["en"] as? String))]
        }
        let output = try JSONSerialization.data(withJSONObject: ["sentences": pairs])
        let choices: [[String: Any]] = [
            ["finish_reason": "stop", "message": ["content": String(decoding: output, as: UTF8.self)]]
        ]
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (try JSONSerialization.data(withJSONObject: ["choices": choices]), response)
    }
}
