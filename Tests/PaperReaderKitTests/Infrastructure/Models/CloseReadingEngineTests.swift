import Foundation
import Testing

@testable import PaperReaderKit

private struct CloseReadingTestInput: Decodable {
    struct Passage: Decodable {
        let source: String
        let anchorText: String
        let tableRows: String?
    }
    let focus: String
    let passages: [Passage]
    let comparisons: [Passage]
}

private func closeReadingFixture(root: URL, texts: [String]) async throws -> Paper {
    let blocks = texts.map { TextBlock(sourcePage: -1, text: $0) }
    var paper = Paper(
        title: "Independent sample", digest: "fixture", originalPath: "absent.pdf", pageCount: 1,
        blocks: blocks, warnings: [], canReflow: true)
    paper.htmlReading = try await HTMLReadingStore().append(
        blocks.map { .init(block: $0, translation: "翻译不能作为新证据。") },
        to: nil, paper: paper, root: root)
    return paper
}

@Test func closeReadingOnlyAcceptsCurrentAnchorsAndVerbatimRegisteredLocalComparisons() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sentence = "A held-out sample improved accuracy from 71% to 78%."
    let paper = try await closeReadingFixture(root: root, texts: [sentence])
    let comparison = Evidence(
        id: "arbitrary", title: "Local replication", text: "Performance varied between cohorts.",
        paperID: UUID(), sourcePage: 0)
    let web = Evidence(id: "arbitrary2", title: "Not in library", text: "An online abstract.")
    let result = try await CloseReadingEngine.run(
        paper: paper, root: root, related: [web, comparison], focus: "核对对照",
        progress: { _ in },
        complete: { system, user in
            let input = try JSONDecoder().decode(CloseReadingTestInput.self, from: Data(user.utf8))
            #expect(input.focus == "核对对照" && input.comparisons.map(\.source) == ["L1"])
            #expect(input.passages.map(\.anchorText) == [sentence])
            #expect(system.contains("captionOnly"))
            let real: [String: Any] = [
                "dimension": "evidence", "source": "P1", "quote": sentence,
                "role": "报告留出样本的比较。", "explanation": "准确率从 71.0% 升到 78%，相差 7 个百分点。",
                "critique": "组间差异是否稳定还需要重复测量。",
                "references": [["source": "L1", "quote": "varied between cohorts", "label": "跨组差异"]],
            ]
            var forged = real
            forged["quote"] = "No differences were observed."
            var badNumber = real
            badNumber["critique"] = "变化已通过 p < 0.001 检验。"
            var wrongDelta = real
            wrongDelta["explanation"] = "从 71% 升到 78%，相差 9 个百分点。"
            var external = real
            external["critique"] = "[全文](file:///outside)"
            var wrongPaper = real
            wrongPaper["source"] = "L1"
            wrongPaper["quote"] = comparison.text
            var unknownLink = real
            unknownLink["references"] = [["source": "P99", "quote": sentence]]
            let stages = [
                [
                    "stage": "evidence", "text": "该实验只检验了留出样本。",
                    "references": [["source": "P1", "quote": sentence]],
                ]
            ]
            return String(
                decoding: try JSONSerialization.data(withJSONObject: [
                    "annotations": [
                        real, forged, badNumber,
                        external, wrongPaper, unknownLink, wrongDelta,
                        ["dimension": "unsupported", "role": "bad schema"],
                    ], "outline": stages,
                ]), as: UTF8.self)
        })
    #expect(result.annotations.map(\.dimension) == [.evidence])
    let note = try #require(result.annotations.first)
    #expect(note.source.paperID == paper.id && note.quote == sentence)
    #expect(note.references.first?.evidence.paperID == comparison.paperID && note.references.first?.label == "跨组差异")
    #expect(note.markdown.contains("**段落作用**") && note.markdown.contains("**审读**"))
    #expect(result.outline.map(\.stage) == CloseReadingStage.allCases)
    #expect(result.outline.first(where: { $0.stage == .rebuttal })?.references.isEmpty == true)
    #expect(result.outline.first(where: { $0.stage == .evidence })?.references.first?.quote == sentence)
    #expect(CloseReadingDimension.allCases.map(\.color) == [.yellow, .red, .blue, .green, .purple])
    #expect(result.coverage.contains("7条候选批注"))
}

@Test func closeReadingHTMLTableWithoutAnOutsideCaptionUsesItsExistingWholeObjectAnchor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let html = """
        <table><caption>Evaluation across folds</caption><tr><th>System</th><th>Score</th></tr>
        <tr><td>Baseline</td><td>61%</td></tr><tr><td>Learned</td><td>74%</td></tr></table>
        """
    var block = TextBlock(sourcePage: -1, text: "Evaluation across folds")
    block.richContent = .init(html: html, translationInput: block.text, mathematics: [:], mathDescriptions: [:])
    var paper = Paper(
        title: "Fixture", digest: "source", originalPath: "fixture.pdf", pageCount: 1, blocks: [block],
        warnings: [], canReflow: true)
    let artifact = try await HTMLReadingStore().append(
        [.init(block: block, translation: nil)], to: nil, paper: paper, root: root)
    paper.htmlReading = artifact
    let corpus = try await CloseReadingCorpus.read(paper: paper, root: root, progress: { _ in })
    let item = try #require(corpus.windows.first?.first)
    #expect(item.kind == "table" && item.table?.contains("Learned\t74%") == true)
    let store = HTMLReadingStore()
    let quote = "Evaluation across folds"
    let anchors = try await store.noteAnchors(
        for: quote, evidence: item.evidence, paperID: paper.id, artifact: artifact, root: root)
    #expect(anchors.count == 1 && anchors[0].target == "object:0" && anchors[0].text.contains("Learned\t74%"))
    let again = try await store.noteAnchors(
        for: quote, evidence: item.evidence, paperID: paper.id, artifact: artifact, root: root, selection: anchors)
    #expect(again == anchors)
}

@Test func closeReadingCombinesMultipleWindowsAndStopsWhenCancelled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = (1...7).map {
        "Window evidence \($0). " + String(repeating: "Repeated source observation. ", count: 112)
    }
    let paper = try await closeReadingFixture(root: root, texts: source)
    let result = try await CloseReadingEngine.run(
        paper: paper, root: root, progress: { _ in },
        complete: { system, user in
            if system.contains("最终综合") {
                #expect(user.contains("N2") && user.contains("W2"))
                return
                    #"{"keep":["N1","N2"],"outline":[{"stage":"evidence","text":"不可采信。","witnesses":["W1","W99"]},{"stage":"evidence","text":"不同段落分别给出观察。","witnesses":["W1","W2"]}]}"#
            }
            let input = try JSONDecoder().decode(CloseReadingTestInput.self, from: Data(user.utf8))
            let p = try #require(input.passages.first)
            let quote = try #require(p.anchorText.split(separator: ".").first).description + "."
            return String(
                decoding: try JSONSerialization.data(withJSONObject: [
                    "annotations": [
                        [
                            "dimension": "method", "source": p.source,
                            "quote": quote, "role": "交代观察过程。", "explanation": "这里规定怎样收集材料。", "critique": "尚需核对抽样方法。",
                        ]
                    ],
                    "outline": [
                        [
                            "stage": "evidence", "text": "作者报告了观察。",
                            "references": [["source": p.source, "quote": quote]],
                        ]
                    ],
                ]), as: UTF8.self)
        })
    #expect(result.annotations.count == 2)
    #expect(result.outline.first { $0.stage == .evidence }?.references.count == 2)
    #expect(result.outline.first { $0.stage == .evidence }?.text == "不同段落分别给出观察。")
    #expect(result.coverage.contains("2/2个文本窗口"))
    let task = Task {
        try await CloseReadingEngine.run(
            paper: paper, root: root, progress: { _ in },
            complete: { _, _ in
                Issue.record("已取消的阅读不应调用模型")
                throw CancellationError()
            })
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

private actor CloseReadingAttempts {
    var windows = 0
    var synthesis = 0
    func window() -> Int {
        windows += 1
        return windows
    }
    func combine() { synthesis += 1 }
}

@Test func closeReadingRetriesTruncatedWindowAndKeepsVerifiedWorkWhenAnotherWindowAndSynthesisFail() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = (1...7).map { "Observation \($0). " + String(repeating: "Original evidence statement. ", count: 112) }
    let paper = try await closeReadingFixture(root: root, texts: source)
    let counter = CloseReadingAttempts()
    let result = try await CloseReadingEngine.run(
        paper: paper, root: root, progress: { _ in },
        complete: { system, user in
            if system.contains("最终综合") {
                await counter.combine()
                return #"{"keep":["N999"]}"#
            }
            let n = await counter.window()
            if n == 1 { throw ModelClient.TruncatedCompletion() }
            if n >= 3 { return #"{"annotations":["# }
            let p = try #require(JSONDecoder().decode(CloseReadingTestInput.self, from: Data(user.utf8)).passages.first)
            return """
                ```json
                {"annotations":[{"dimension":"method","source":"\(p.source)","quote":"Observation","role":"方法","explanation":"说明观察步骤","critique":"没有给出不确定度"}],"outline":[{"stage":"evidence","text":"描述了观察。","references":[{"source":"\(p.source)","quote":"Observation"}]}]}
                ```
                """
        })
    #expect(await counter.windows == 4)
    #expect(await counter.synthesis == 2)
    #expect(result.annotations.count == 1 && result.outline.first { $0.stage == .evidence }?.references.count == 1)
    #expect(
        result.coverage.contains("已分析1/2") && result.coverage.contains("第 2 组") && result.coverage.contains("采用分组核实"))
}
