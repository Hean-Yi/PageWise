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
    let readingNotes: [Passage]
    let alreadyDiscussed: [String]
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
        paperID: UUID(), readingNoteID: UUID())
    let web = Evidence(id: "arbitrary2", title: "Not in library", text: "An online abstract.")
    let result = try await CloseReadingEngine.run(
        paper: paper, root: root, focus: "核对对照",
        retrieveNotes: { query in
            #expect(query.contains("held-out sample"))
            let rawPaper = Evidence(id: "other", title: "Unannotated", text: sentence, paperID: UUID(), sourcePage: 0)
            return [web, rawPaper, comparison]
        },
        progress: { _ in },
        complete: { system, user in
            let input = try JSONDecoder().decode(CloseReadingTestInput.self, from: Data(user.utf8))
            #expect(input.focus == "核对对照" && input.readingNotes.map(\.source) == ["L1"])
            #expect(input.passages.map(\.anchorText) == [sentence])
            #expect(system.contains("captionOnly"))
            let real: [String: Any] = [
                "dimension": "evidence", "source": "P1", "quote": sentence,
                "analysis": "留出样本的准确率从 71.0% 升到 78%，相差 7 个百分点。组间差异是否稳定还需要重复测量。",
                "references": [["source": "L1", "quote": "varied between cohorts", "label": "跨组差异"]],
            ]
            var forged = real
            forged["quote"] = "No differences were observed."
            var badNumber = real
            badNumber["analysis"] = "变化已通过 p < 0.001 检验。"
            var wrongDelta = real
            wrongDelta["analysis"] = "从 71% 升到 78%，相差 9 个百分点。"
            var external = real
            external["analysis"] = "[全文](file:///outside)"
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
    #expect(note.markdown == "留出样本的准确率从 71.0% 升到 78%，相差 7 个百分点。组间差异是否稳定还需要重复测量。")
    #expect(result.outline.map(\.stage) == [.evidence])
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

@Test func closeReadingKeepsOneInsightPerPassageAndLinksTheControlThatChangesItsInterpretation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let claim = "The new retriever won the benchmark. Its default used a larger pool."
    let control = "With equal pools both retrievers scored 73%."
    let extra = "The appendix repeats the benchmark result."
    let paper = try await closeReadingFixture(root: root, texts: [claim, control, extra])
    let analysis = "扩大候选池本身就可能改善检索；对齐候选池后两者同为 73%，这个对照无法把默认配置的优势归给检索算法。"
    let result = try await CloseReadingEngine.run(
        paper: paper, root: root, progress: { _ in },
        complete: { _, _ in
            let ref = ["source": "P2", "quote": control, "label": "等量候选池对照"]
            func item(_ source: String, _ quote: String, _ body: String) -> [String: Any] {
                ["source": source, "quote": quote, "dimension": "evidence", "analysis": body, "references": [ref]]
            }
            let rows = [
                item("P1", "The new retriever won the benchmark.", "P2的对照说明，" + analysis),
                item("P1", "Its default used a larger pool.", "较大的候选池也改变了比较条件。"),
                item("P3", extra, "P2的对照说明，" + analysis), item("P2", control, "同等规模下，两种方法在这个测试上的得分一致。"),
            ]
            return String(
                decoding: try JSONSerialization.data(withJSONObject: ["annotations": rows, "outline": []]),
                as: UTF8.self)
        })
    #expect(result.annotations.map(\.source.id) == ["P1", "P2"])
    #expect(result.annotations.first?.markdown == "原文的对照说明，" + analysis)
    #expect(result.annotations.first?.references.first?.quote == control)
    #expect(result.outline.isEmpty)
}

@Test func closeReadingRetainsMatchedControlAndChecksItsPercentagePointGapAgainstOneComparison() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaultRun = "At different budgets Copper scores 82% and Slate scores 68%."
    let control = "At equal budgets of 4 paths each Copper scores 69% and Slate scores 68%."
    let paper = try await closeReadingFixture(root: root, texts: [defaultRun, control])
    let first = "默认设置相差 14 个百分点。"
    let second = "对齐预算后只差 1 个百分点，默认差距混入了搜索范围的影响。"
    let result = try await CloseReadingEngine.run(
        paper: paper, root: root, progress: { _ in },
        complete: { _, _ in
            let ref = ["source": "P1", "quote": defaultRun]
            func item(_ text: String) -> [String: Any] {
                ["dimension": "evidence", "source": "P2", "quote": control, "analysis": text, "references": [ref]]
            }
            let stages: [[String: Any]] = [
                ["stage": "evidence", "text": first, "references": [ref]],
                ["stage": "evidence", "text": second, "references": [["source": "P2", "quote": control]]],
            ]
            let rows = [
                item("两种预算相差 4 个百分点。"),  // The number of paths is not a score gap.
                item("对齐后相差 13 个百分点。"),  // 82 − 69 pairs values from different experiments.
                item("默认相差 14 个百分点，对齐预算后只差 1 个百分点。"),
            ]
            return String(
                decoding: try JSONSerialization.data(withJSONObject: ["annotations": rows, "outline": stages]),
                as: UTF8.self)
        })
    #expect(result.annotations.map(\.markdown) == ["默认相差 14 个百分点，对齐预算后只差 1 个百分点。"])
    #expect(result.outline.map(\.text) == [first + "\n\n" + second])
    #expect(result.outline.first?.references.map(\.quote) == [defaultRun, control])
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
            #expect(p.source == "P1" ? input.alreadyDiscussed.isEmpty : input.alreadyDiscussed.count == 1)
            var refs = [["source": p.source, "quote": quote]]
            if p.source == "P1" {
                let second = try #require(input.passages.dropFirst().first)
                let secondQuote = try #require(second.anchorText.split(separator: ".").first).description + "."
                refs.append(["source": second.source, "quote": secondQuote])
            }
            return String(
                decoding: try JSONSerialization.data(withJSONObject: [
                    "annotations": [
                        [
                            "dimension": "method", "source": p.source,
                            "quote": quote, "analysis": "\(quote) 将这一批观察单列，不能据此合并不同窗口的样本。",
                        ]
                    ],
                    "outline": [
                        [
                            "stage": "evidence", "text": "作者报告了观察。",
                            "references": refs,
                        ]
                    ],
                ]), as: UTF8.self)
        })
    #expect(result.annotations.count == 2)
    #expect(result.outline.first { $0.stage == .evidence }?.references.count == 3)
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
                {"annotations":[{"dimension":"method","source":"\(p.source)","quote":"Observation","analysis":"这些记录没有给出批次之间的波动。"}],"outline":[{"stage":"evidence","text":"描述了观察。","references":[{"source":"\(p.source)","quote":"Observation"}]}]}
                ```
                """
        })
    #expect(await counter.windows == 4)
    #expect(await counter.synthesis == 2)
    #expect(result.annotations.count == 1 && result.outline.first { $0.stage == .evidence }?.references.count == 1)
    #expect(
        result.coverage.contains("已分析1/2") && result.coverage.contains("第 2 组") && result.coverage.contains("采用分组核实"))
}
