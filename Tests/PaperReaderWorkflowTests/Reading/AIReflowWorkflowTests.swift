import Foundation
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

private actor JointReflowTransport: HTTPTransport {
    var calls = 0
    var outputLimitOnce: Bool
    let outputLimitAlways: Bool
    let excludeMetadata: Bool
    var tokenBudgets: [Int] = []
    var interruptOnce: Bool
    var models: [String] = []
    var holdOnce: Bool
    var malformedOnce: Bool
    var unknownFormulaOnce: Bool
    let alwaysMalformed: Bool
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    init(
        interruptOnce: Bool = false, holdOnce: Bool = false, malformedOnce: Bool = false, alwaysMalformed: Bool = false,
        outputLimitOnce: Bool = false, outputLimitAlways: Bool = false, excludeMetadata: Bool = false,
        unknownFormulaOnce: Bool = false
    ) {
        self.unknownFormulaOnce = unknownFormulaOnce
        self.outputLimitOnce = outputLimitOnce
        self.outputLimitAlways = outputLimitAlways
        self.excludeMetadata = excludeMetadata
        self.interruptOnce = interruptOnce
        self.holdOnce = holdOnce
        self.malformedOnce = malformedOnce
        self.alwaysMalformed = alwaysMalformed
    }
    func release() {
        continuation?.resume()
        continuation = nil
        waiting = false
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
    {
        calls += 1
        if alwaysMalformed {
            try await onData(Data("data: {\"choices\":[{\"delta\":{\"content\":\"invalid JSON\"}}]}\n\n".utf8))
            throw AIReflowFailure.invalidStructure
        }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        models.append(body["model"] as! String)
        tokenBudgets.append(body["max_tokens"] as! Int)
        if outputLimitAlways {
            try await onData(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n".utf8))
            throw ModelStreamFailure.outputLimit
        }
        let messages = body["messages"] as! [[String: Any]]
        if body["response_format"] == nil {
            let output = unknownFormulaOnce ? "这是错误的译文[[MATH_n]]。" : "这是完整的恢复译文。"
            unknownFormulaOnce = false
            let packet = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": output]]]])
            try await onData(Data("data: ".utf8) + packet + Data("\n\n".utf8))
            try await onData(
                Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
        let input =
            try JSONSerialization.jsonObject(with: Data((messages[1]["content"] as! String).utf8)) as! [String: Any]
        let sources = input["sources"] as! [[String: Any]]
        let excludeMetadata = self.excludeMetadata
        let blocks =
            input["accepted_plan"] as? [[String: Any]]
            ?? sources.enumerated().map { index, source in
                [
                    "block_index": index,
                    "kind": excludeMetadata
                        && (source["original_text"] as? String)?.hasPrefix("Correspondence:") == true
                        ? "front_matter" : source["kind"]!,
                    "source_segments": [
                        ["source_id": source["source_id"]!, "start_utf16": 0, "end_utf16": source["end_utf16"]!]
                    ], "object_refs": (source["objects"] as! [[String: Any]]).map { $0["object_id"]! },
                ] as [String: Any]
            }
        let committed = Set(input["committed_block_indices"] as! [Int])
        var events: [[String: Any]] =
            input["accepted_plan"] == nil
            ? [["type": "window_plan", "blocks": blocks, "dispositions": [], "carry": []]]
            : [["type": "window_resume", "block_index": committed.count]]
        var translated = 0
        var completed = committed.count
        for index in blocks.indices where !committed.contains(index) {
            let kind = blocks[index]["kind"] as! String
            let translates = !["front_matter", "non_content", "figure", "preserved_source", "bibliography", "code"]
                .contains(kind)
            if translates && translated >= (input["max_translation_blocks"] as? Int ?? 128) { break }
            events.append(["type": "block_start", "block_index": index])
            if translates {
                events.append([
                    "type": "translation_delta", "block_index": index,
                    "parts": [["type": "text", "text": "这是完整的测试译文，保留原文含义。"]],
                ])
                translated += 1
            }
            events.append(["type": "block_end", "block_index": index])
            completed += 1
        }
        events.append(["type": completed == blocks.count ? "window_end" : "window_pause", "block_count": blocks.count])
        for (seq, event) in events.enumerated() {
            var event = event
            event["seq"] = seq
            event["v"] = 1
            event["request_id"] = input["request_id"]!
            event["window_id"] = input["window_id"]!
            let prefix = seq == 0 ? "{\"events\":[" : ","
            let suffix = seq == events.count - 1 ? "]}" : ""
            let content =
                prefix + String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)! + suffix
            let packet = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": content]]]])
            try await onData(Data("data: ".utf8) + packet + Data("\n\n".utf8))
            if outputLimitOnce && event["type"] as? String == "block_end" {
                outputLimitOnce = false
                try await onData(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n".utf8))
                throw ModelStreamFailure.outputLimit
            }
            if malformedOnce && event["type"] as? String == "block_end" {
                malformedOnce = false
                try await onData(Data("data: {\"choices\":[{\"delta\":{\"content\":\",invalid JSON\"}}]}\n\n".utf8))
                throw AIReflowFailure.invalidStructure
            }
            if holdOnce && event["type"] as? String == "block_end" {
                holdOnce = false
                waiting = true
                await withCheckedContinuation { continuation = $0 }
            }
            if interruptOnce && event["type"] as? String == "block_end" {
                interruptOnce = false
                throw URLError(.networkConnectionLost)
            }
        }
        try await onData(
            Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

@Test @MainActor func importingPDFAndReadingOriginalNeverStartsReflow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pdf = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: pdf)
    let original = try Data(contentsOf: pdf)
    let transport = JointReflowTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let imported = await model.importURLs([pdf])
    #expect(imported.count == 1)
    let paper = try #require(model.paper)
    #expect(paper.blocks.isEmpty && paper.htmlReading == nil && paper.reflowJob == nil)
    #expect(!paper.canReflow)
    #expect(!model.readingChoicePresented)
    model.readOriginal()
    #expect(!model.readingChoicePresented && model.mode == "original")
    #expect(await transport.calls == 0)
    #expect(try Data(contentsOf: root.appendingPathComponent(paper.originalPath)) == original)
}

@Test(arguments: [false, true])
@MainActor func sourceReflowUsesTheLocalTranslationKeyWithOrWithoutSavedSettings(saved: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var approved = ModelSettings()
    approved.baseURL = "https://api.deepseek.com"
    approved.model = "deepseek-flash"
    let local = PDFTranslationValidationConfiguration(settings: approved, key: "local-test-only")
    let credentials = WorkflowCredentials()
    credentials.values = [:]
    let transport = JointReflowTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: credentials, translationValidation: local)
    await model.load()
    if saved { try model.saveSettings(approved, key: nil) }
    #expect(try await model.modelKey(for: model.translationSettings).isEmpty)
    var paper = Paper(
        title: "Source fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: true)
    paper.reflowJob = ReflowJob(sources: [TextBlock(sourcePage: 0, text: "A complete source paragraph.")])
    paper.reflowJob?.evidenceRoute = "tex"
    model.state.papers = [paper]
    model.select(paper.id)
    model.startAIReflow()
    try await waitForReflow(model, id: paper.id)
    #expect(await transport.models == [approved.model])
    #expect(model.paper?.reflowJob?.finished == true)
    #expect(model.paper?.translations.count == 1)
}

@Test @MainActor func coldLoaderAppearsBeforeCredentialReadOrCheckpointCreation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await model.load()
    var settings = model.modelSettings
    settings.model = "test"
    try model.saveSettings(settings, key: nil)
    var paper = Paper(
        title: "Loading", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: true)
    paper.onlineSource = OnlinePaperSource(candidateID: "https://arxiv.org/abs/0000.00000v1")
    model.state.papers = [paper]
    model.select(paper.id)
    model.startAIReflow()
    #expect(model.paper?.reflowJob == nil)
    #expect(model.showingReflowLoading)
    model.pauseTranslation()
    for _ in 0..<100 where !model.translating.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
}

@Test @MainActor func jointReflowResumesCommittedPrefixWithoutDuplicatingOrChangingIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = JointReflowTransport(interruptOnce: true)
    let credentials = WorkflowCredentials()
    let model = try ReaderModel(root: root, client: ModelClient(transport: transport), credentials: credentials)
    await model.load()
    var settings = model.modelSettings
    settings.baseURL = "https://example.invalid/v1"
    settings.model = "fixture"
    try model.saveSettings(settings, key: "test-only")
    var paper = Paper(
        title: "Original fixture", digest: "fixture", originalPath: "unused.pdf", pageCount: 1, blocks: [],
        warnings: [], canReflow: true)
    paper.reflowJob = ReflowJob(sources: [
        TextBlock(sourcePage: 0, text: "The first complete source paragraph."),
        TextBlock(sourcePage: 0, text: "The second complete source paragraph."),
    ])
    paper.reflowJob?.evidenceRoute = "html"
    model.state.papers = [paper]
    model.select(paper.id)
    model.startAIReflow()
    try await waitForReflow(model, id: paper.id)
    let first = try #require(model.paper)
    #expect(first.blocks.count == 1)
    #expect(first.reflowJob?.acceptedPlan != nil)
    #expect(first.reflowJob?.failure != nil)
    let firstID = first.blocks[0].id
    let firstTranslation = first.translations[firstID.uuidString]
    let initialHTML = try String(
        contentsOf: root.appendingPathComponent(try #require(first.htmlReading).relativePath), encoding: .utf8)
    let reopened = try ReaderModel(root: root, client: ModelClient(transport: transport), credentials: credentials)
    await reopened.load()
    reopened.select(paper.id)
    reopened.startAIReflow()
    try await waitForReflow(reopened, id: paper.id)
    let completed = try #require(reopened.paper)
    #expect(completed.reflowJob?.finished == true)
    #expect(completed.blocks.count == 2 && completed.blocks[0].id == firstID)
    #expect(completed.translations[firstID.uuidString] == firstTranslation)
    #expect(Set(completed.blocks.map(\.id)).count == 2)
    let finalHTML = try String(
        contentsOf: root.appendingPathComponent(try #require(completed.htmlReading).relativePath), encoding: .utf8)
    let sectionStart = try #require(initialHTML.range(of: "<section id="))
    let sectionEnd = try #require(
        initialHTML.range(of: "</section>", range: sectionStart.lowerBound..<initialHTML.endIndex))
    let sealedSection = String(initialHTML[sectionStart.lowerBound..<sectionEnd.upperBound])
    #expect(finalHTML.contains(sealedSection))
    #expect(await transport.calls == 2)
    #expect(reopened.showingReflowLoading)
    reopened.reportReflowReadiness(
        paperID: paper.id, bodyCount: 2, bodyHeight: 800, viewportHeight: 500, resourcesReady: true)
    for _ in 0..<100 where reopened.showingReflowLoading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!reopened.showingReflowLoading)
}

@MainActor private func waitForReflow(_ model: ReaderModel, id: UUID) async throws {
    for _ in 0..<300 {
        if !model.translating.contains(id) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Reflow task did not terminate")
}

@Test @MainActor func onlineTeXImportReflowRestartAndRegenerationKeepSourceAndOldReading() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pdf = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: pdf)
    let original = try Data(contentsOf: pdf)
    let transport = JointReflowTransport(interruptOnce: true)
    let credentials = WorkflowCredentials()
    let model = try ReaderModel(root: root, client: ModelClient(transport: transport), credentials: credentials)
    await model.load()
    var settings = model.modelSettings
    settings.model = "fixture"
    try model.saveSettings(settings, key: nil)
    let candidate = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001v1", title: "Original TeX fixture", authors: "", year: "",
        pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001v1")!)
    let source = Data(
        #"""
        \documentclass{article}
        \title{Original TeX fixture}
        \begin{document}
        \maketitle
        The first paragraph comes from the source package.

        The second paragraph has an independent stable source identity.
        \end{document}
        """#.utf8)
    let download = DownloadedPublication(pdfURL: pdf, candidate: candidate, texArchive: source)
    let ids = await model.importURLs([pdf], metadata: candidate, onlineDownload: download)
    let id = try #require(ids.first)
    let imported = try #require(model.paper)
    #expect(imported.blocks.isEmpty && imported.reflowJob == nil)
    #expect(await transport.calls == 0)
    let sourcePath = try #require(imported.onlineSource?.archivePath)
    #expect(try Data(contentsOf: root.appendingPathComponent(sourcePath)) == source)
    model.startAIReflow()
    try await waitForReflow(model, id: id)
    let first = try #require(model.paper?.blocks.first)
    #expect(model.paper?.reflowJob?.evidenceRoute == "tex")
    #expect(model.paper?.reflowJob?.sources.allSatisfy { $0.sourcePage == -1 } == true)
    #expect(first.reflowProvenance?.first?.texSource != nil)
    let reopened = try ReaderModel(root: root, client: ModelClient(transport: transport), credentials: credentials)
    await reopened.load()
    reopened.select(id)
    reopened.startAIReflow()
    try await waitForReflow(reopened, id: id)
    let completed = try #require(reopened.paper)
    #expect(completed.reflowJob?.finished == true)
    #expect(completed.blocks.count == 3)
    #expect(completed.blocks.first?.id == first.id)
    let artifact = try #require(completed.htmlReading)
    let sealed = try Data(contentsOf: root.appendingPathComponent(artifact.relativePath))
    reopened.startAIReflow(regenerate: true)
    try await waitForReflow(reopened, id: id)
    #expect(reopened.paper?.reflowJob?.finished == true)
    #expect(reopened.paper?.retainedReadings?.last?.html == artifact)
    #expect(try Data(contentsOf: root.appendingPathComponent(artifact.relativePath)) == sealed)
    #expect(try Data(contentsOf: root.appendingPathComponent(imported.originalPath)) == original)
    let duplicate = await reopened.importURLs([pdf], metadata: candidate, onlineDownload: download)
    #expect(duplicate == [id])
    #expect(reopened.state.papers.count == 1)
    #expect(try Data(contentsOf: root.appendingPathComponent(sourcePath)) == source)
}

@Test @MainActor func onlineDuplicateCanAttachSourceWithoutReplacingExistingPDFJob() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pdf = root.appendingPathComponent("fixture.pdf")
    try DemoPaper.write(to: pdf)
    let model = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await model.load()
    let ids = await model.importURLs([pdf])
    let id = try #require(ids.first)
    let job = ReflowJob(sources: [TextBlock(sourcePage: 0, text: "Saved PDF evidence")])
    model.state.papers[0].reflowJob = job
    _ = await model.save()
    let candidate = PaperCandidate(
        id: "https://arxiv.org/abs/2401.00001v1", title: "Original fixture", authors: "", year: "",
        pdfURL: URL(string: "https://arxiv.org/pdf/2401.00001v1")!)
    let source = Data(#"\documentclass{article}\begin{document}Original source.\end{document}"#.utf8)
    let download = DownloadedPublication(pdfURL: pdf, candidate: candidate, texArchive: source)
    #expect(await model.importURLs([pdf], metadata: candidate, onlineDownload: download) == [id])
    #expect(model.paper?.reflowJob == job)
    #expect(model.paper?.onlineSource?.archivePath != nil)
    let restored = try await LibraryStore(directory: root).load()
    #expect(restored.papers.first?.reflowJob == job)
    #expect(restored.papers.first?.onlineSource?.archiveDigest == TeXPaperParser.digest(source))
}

@Test @MainActor func changingModelStopsOldGenerationAndResumesOnlyUnpublishedSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = JointReflowTransport(holdOnce: true)
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    var settings = model.modelSettings
    settings.model = "first-model"
    try model.saveSettings(settings, key: nil)
    let sources = [
        TextBlock(sourcePage: 0, text: "First original paragraph."),
        TextBlock(sourcePage: 1, text: "Second original paragraph."),
    ]
    var paper = Paper(
        title: "Switch", digest: "fixture", originalPath: "unused.pdf", pageCount: 2, blocks: [], warnings: [],
        canReflow: true)
    paper.reflowJob = ReflowJob(sources: sources)
    paper.reflowJob?.evidenceRoute = "html"
    model.state.papers = [paper]
    model.select(paper.id)
    model.startAIReflow()
    for _ in 0..<300 {
        if await transport.waiting { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.waiting)
    let committed = try #require(model.paper?.blocks.first)
    settings.model = "second-model"
    try model.saveSettings(settings, key: nil)
    await transport.release()
    for _ in 0..<300 where !model.translating.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.paper?.blocks.count == 1)
    #expect(await transport.calls == 1)
    model.startAIReflow()
    for _ in 0..<300 where !model.translating.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.paper?.reflowJob?.finished == true)
    #expect(model.paper?.blocks.first?.id == committed.id)
    #expect(model.paper?.blocks.count == 2)
    #expect(await transport.models == ["first-model", "second-model"])
}

@Test(arguments: [false, true], [false, true]) @MainActor
func structuralRecoveryRetainsPrefixAndHasABoundedRequestCount(alwaysMalformed: Bool, unknownFormula: Bool) async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = JointReflowTransport(
        malformedOnce: !alwaysMalformed, alwaysMalformed: alwaysMalformed, unknownFormulaOnce: unknownFormula)
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    var settings = model.modelSettings
    settings.model = "fixture"
    try model.saveSettings(settings, key: nil)
    let sources = [
        TextBlock(sourcePage: 0, text: "First original paragraph."),
        TextBlock(sourcePage: 1, text: "Second original paragraph."),
    ]
    var paper = Paper(
        title: "Recovery", digest: "fixture", originalPath: "unused.pdf", pageCount: 2, blocks: [], warnings: [],
        canReflow: true)
    paper.reflowJob = ReflowJob(sources: sources)
    paper.reflowJob?.evidenceRoute = "html"
    model.state.papers = [paper]
    model.select(paper.id)
    model.startAIReflow()
    for _ in 0..<300 where !model.translating.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await transport.calls == (alwaysMalformed || unknownFormula ? 3 : 2))
    #expect(model.paper?.reflowJob?.finished == !alwaysMalformed)
    #expect(model.paper?.blocks.count == (alwaysMalformed ? 0 : 2))
    #expect(model.paper?.reflowJob?.completedSourceIDs.count == (alwaysMalformed ? 0 : 2))
    if !alwaysMalformed {
        #expect(model.translationPauseReason == nil)
        #expect(model.paper?.translations.values.allSatisfy { !$0.contains("[[MATH_") } == true)
    }
}

@Test(arguments: [false, true]) @MainActor
func outputLimitAutomaticallyContinuesAndBoundsNoProgressRetries(stalled: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = JointReflowTransport(outputLimitOnce: !stalled, outputLimitAlways: stalled)
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    var settings = model.modelSettings
    settings.model = "fixture"
    try model.saveSettings(settings, key: nil)
    let sources = (0..<5).map { index in
        let source = TextBlock(sourcePage: 0, text: "Original body paragraph number \(index).")
        return source
    }
    var paper = Paper(
        title: "Continuity", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: true)
    paper.reflowJob = ReflowJob(sources: sources)
    paper.reflowJob?.evidenceRoute = "html"
    model.state.papers = [paper]
    model.select(paper.id)
    model.startAIReflow()
    try await waitForReflow(model, id: paper.id)
    #expect(await transport.calls == (stalled ? 3 : 4))
    if stalled {
        #expect(model.paper?.blocks.isEmpty == true)
        #expect(model.paper?.reflowJob?.finished == false)
        #expect(model.translationPauseReason?.contains("连续未能完成") == true)
        #expect(await transport.tokenBudgets == [8192, 16384, 32768])
    } else {
        #expect(model.paper?.reflowJob?.finished == true)
        #expect(model.translationPauseReason == nil)
        #expect(model.paper?.blocks.count == 5)
        #expect(
            Set(model.paper?.blocks.flatMap { $0.reflowProvenance?.map(\.sourceID) ?? [] } ?? [])
                == Set(sources.map(\.id)))
        #expect(model.paper?.reflowJob?.acceptedPlan == nil)
        #expect(await transport.tokenBudgets == [8192, 4096, 4096, 8192])
    }
}

@Test @MainActor func excludedAuthorMetadataNeverPublishesOrReappearsAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = JointReflowTransport(excludeMetadata: true)
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    var settings = model.modelSettings
    settings.model = "fixture"
    try model.saveSettings(settings, key: nil)
    var author = TextBlock(sourcePage: 0, text: "Correspondence: author@example.invalid")
    let body = TextBlock(sourcePage: 0, text: "The experiment measures the performance of the proposed method.")
    var paper = Paper(
        title: "Body only", digest: "fixture", originalPath: "unused.pdf", pageCount: 1,
        blocks: [], warnings: [], canReflow: true)
    author.richContent = RichContent(
        html: "<div class='front-matter'>Correspondence: author@example.invalid</div>", translationInput: "",
        mathematics: [:], mathDescriptions: [:])
    paper.reflowJob = ReflowJob(sources: [author, body])
    paper.reflowJob?.evidenceRoute = "html"
    model.state.papers = [paper]
    model.select(paper.id)
    model.startAIReflow()
    try await waitForReflow(model, id: paper.id)
    let result = try #require(model.paper)
    #expect(result.reflowJob?.finished == true)
    #expect(result.blocks.map(\.text) == [body.text])
    #expect(result.reflowJob?.excludedSourceIDs == [author.id])
    #expect(result.reflowJob?.completedSourceIDs == [author.id, body.id])
    #expect(result.reflowJob?.sources.first?.text == author.text)
    let html = try String(
        contentsOf: root.appendingPathComponent(try #require(result.htmlReading).relativePath), encoding: .utf8)
    #expect(!html.contains(author.text))
    #expect(result.htmlReading?.sections.count == 1)
    let reloaded = try await LibraryStore(directory: root).load()
    #expect(reloaded.papers.first?.reflowJob?.excludedSourceIDs == [author.id])
}

@Test(arguments: [nil, "pdf"] as [String?]) @MainActor
func legacyPDFJobsRemainReadableButCannotGenerate(route: String?) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = JointReflowTransport()
    let model = try ReaderModel(
        root: root, client: ModelClient(transport: transport), credentials: WorkflowCredentials())
    await model.load()
    let block = TextBlock(sourcePage: 0, text: "Previously published evidence.")
    var paper = Paper(
        title: "Legacy", digest: "fixture", originalPath: "unused.pdf", pageCount: 1, blocks: [block], warnings: [],
        canReflow: true)
    paper.htmlReading = try await HTMLReadingStore().append(
        [BilingualBlock(block: block, translation: "已发布译文。")], to: nil, paper: paper, root: root)
    paper.reflowJob = ReflowJob(sources: [block])
    paper.reflowJob?.evidenceRoute = route
    let file = root.appendingPathComponent(try #require(paper.htmlReading).relativePath)
    let bytes = try Data(contentsOf: file)
    model.state.papers = [paper]
    #expect(await model.save())
    model.select(paper.id)
    model.startAIReflow()
    #expect(model.translating.isEmpty)
    #expect(await transport.calls == 0)
    #expect(model.message != nil)
    #expect(!model.showingReflowLoading)
    let loaded = try await LibraryStore(directory: root).load()
    #expect(loaded.papers.first?.reflowJob == paper.reflowJob)
    #expect(loaded.papers.first?.htmlReading == paper.htmlReading)
    #expect(try Data(contentsOf: file) == bytes)
}
