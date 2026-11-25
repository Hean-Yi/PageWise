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

private struct CloseReadingNotebookInput: Decodable {
    struct Candidate: Decodable {
        let id: String
        let kind: String
        let summary: String
        let sources: [String]
    }
    struct Source: Decodable {
        let id: String
        let kind: String
        let quote: String
        let context: String?
        let tableRows: String?
    }
    let annotations: [Candidate]
    let outlineEvidence: [Candidate]
    let sources: [Source]

    static func read(_ json: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    func response() throws -> String {
        let candidates = outlineEvidence.isEmpty ? annotations : outlineEvidence
        let sections: [[String: Any]] = candidates.map {
            ["heading": "怎样解释这个对照？", "markdown": $0.summary, "sources": $0.sources]
        }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "keep": annotations.map(\.id), "sections": sections,
            ]), as: UTF8.self)
    }
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
            if system.contains("最终综合") { return try CloseReadingNotebookInput.read(user).response() }
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
    #expect(result.sections.map(\.heading) == ["怎样解释这个对照？"])
    #expect(result.sections.first?.references.first?.quote == sentence)
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

@Test func closeReadingCanExplainPublishedEquationsAndLinkTheOriginalObject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sentence = "The uncertainty weight scales the penalty."
    let formula = #"L=\lambda d^2"#
    let markup =
        #"<math display="block" alttext="\#(formula)"><mrow><mi>L</mi><mo>=</mo><mi>λ</mi><msup><mi>d</mi><mn>2</mn></msup></mrow></math>"#
    var block = TextBlock(sourcePage: 0, text: sentence)
    let repeated = #"<math display="block" alttext="a=b"><mi>a</mi><mo>=</mo><mi>b</mi></math>"#
    let unlabelled = #"<math display="block"><mfrac><mi>x</mi><mi>y</mi></mfrac></math>"#
    block.richContent = .init(
        html: "<p>\(sentence)" + markup + "This second sentence follows the equation.</p>" + repeated + unlabelled
            + repeated, translationInput: "[[MATH_1]]",
        mathematics: ["[[MATH_1]]": markup], mathDescriptions: ["[[MATH_1]]": formula])
    var paper = Paper(
        title: "Variance weighting", digest: "formula", originalPath: "unused.pdf", pageCount: 1, blocks: [block],
        warnings: [], canReflow: true)
    let artifact = try await HTMLReadingStore().append(
        [.init(block: block, translation: "译文 [[MATH_1]]")], to: nil, paper: paper, root: root)
    paper.htmlReading = artifact
    let corpus = try await CloseReadingCorpus.read(paper: paper, root: root, progress: { _ in })
    let prose = corpus.windows.flatMap { $0 }.filter { $0.kind == "prose" }
    #expect(prose.map(\.evidence.text) == [sentence, "This second sentence follows the equation."])
    for run in prose {
        let anchors = try await HTMLReadingStore().noteAnchors(
            for: run.evidence.text, evidence: run.evidence, paperID: paper.id, artifact: artifact, root: root)
        #expect(anchors.map(\.text).joined() == run.evidence.text)
    }
    let body = """
        权重控制的是一次偏差会付出多少代价。

        1. 固定偏差，调高权重会放大这项损失。
        2. 固定权重，偏差的作用取决于平方项。

        ### 第 3 步：检查这个解释

        > 这还不能说明高权重的配置训练更稳定。要检验这个解释，应固定样本并观察更新时的波动。
        """
    let result = try await CloseReadingEngine.run(
        paper: paper, root: root, progress: { _ in },
        complete: { system, user in
            if system.contains("最终综合") { return try CloseReadingNotebookInput.read(user).response() }
            let input = try JSONDecoder().decode(CloseReadingTestInput.self, from: Data(user.utf8))
            let equation = try #require(input.passages.first { $0.anchorText == "[公式] " + formula })
            let prose = try #require(input.passages.first { $0.anchorText == sentence })
            #expect(input.passages.count == 3)
            func annotation(citing quote: String) -> [String: Any] {
                [
                    "source": prose.source, "quote": sentence, "dimension": "method", "analysis": body,
                    "references": [["source": equation.source, "quote": quote, "label": "权重的作用"]],
                ]
            }
            let rows = [annotation(citing: "L"), annotation(citing: formula)]
            return String(
                decoding: try JSONSerialization.data(withJSONObject: ["annotations": rows, "outline": []]),
                as: UTF8.self)
        })
    #expect(result.annotations.count == 1)
    let note = try #require(result.annotations.first)
    #expect(note.markdown == body)
    let witness = try #require(note.references.first)
    #expect(witness.quote == "[公式] " + formula)
    let anchors = try await HTMLReadingStore().noteAnchors(
        for: witness.quote, evidence: witness.evidence, paperID: paper.id, artifact: artifact, root: root)
    #expect(anchors.map(\.target) == ["object:0"])
    #expect(anchors.first?.text == "[公式] " + formula)
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
        complete: { system, user in
            if system.contains("最终综合") { return try CloseReadingNotebookInput.read(user).response() }
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
    #expect(!result.sections.isEmpty)
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
        complete: { system, user in
            if system.contains("最终综合") { return try CloseReadingNotebookInput.read(user).response() }
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
    #expect(result.sections.map(\.markdown) == [first, second])
    #expect(result.sections.flatMap(\.references).map(\.quote) == [defaultRun, control])
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
                let input = try CloseReadingNotebookInput.read(user)
                #expect(input.annotations.map(\.id) == ["N1", "N2"] && input.sources.count == 3)
                return
                    #"{"keep":["N1","N2"],"sections":[{"heading":"不可采信","markdown":"虚构了引文。","sources":["Q1","Q99"]},{"heading":"观察怎样形成？","markdown":"不同段落分别给出观察。","sources":["Q1","Q2","Q3"]}]}"#
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
    #expect(result.sections.first?.references.count == 3)
    #expect(result.sections.first?.markdown == "不同段落分别给出观察。")
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
    #expect(result.annotations.count == 1 && result.sections.first?.references.count == 1)
    #expect(result.sections.first?.markdown == result.annotations.first?.markdown)
    #expect(
        result.coverage.contains("已分析1/2") && result.coverage.contains("第 2 组") && result.coverage.contains("采用分组核实"))
}

@Test(arguments: [true, false]) func closeReadingReportsTheProviderOutputLimit(atWindow: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let statement = "The judge sees the label."
    let paper = try await closeReadingFixture(root: root, texts: [statement])
    do {
        let analysis = try await CloseReadingEngine.run(
            paper: paper, root: root, progress: { _ in },
            complete: { _, json in
                guard !atWindow,
                    let input = try? JSONDecoder().decode(CloseReadingTestInput.self, from: Data(json.utf8)),
                    let source = input.passages.first?.source
                else { throw ModelClient.TruncatedCompletion() }
                return """
                    {"annotations":[],"outline":[{"stage":"thesis","text":"裁判可见标签。","references":[{"source":"\(source)","quote":"\(statement)"}]}]}
                    """
            })
        #expect(!atWindow && analysis.coverage.contains("文末写作重试后仍达到模型输出长度上限"))
        #expect(analysis.sections.first?.markdown == "裁判可见标签。")
    } catch {
        #expect(atWindow && error.localizedDescription.contains("第 1 组在重试后仍达到模型输出长度上限"))
    }
}

@Test func closeReadingNotebookWritesLongEvidenceLinkedMarkdownForASingleWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let mechanism = "The judge sees the label and the prefix. The learner only sees the prefix in condition Q17."
    let result = "At matched budgets the label-aware judge reached 74% and the baseline reached 71%."
    var paper = try await closeReadingFixture(root: root, texts: [mechanism, result])
    var ablation = TextBlock(sourcePage: -1, text: "Control with hidden labels")
    ablation.richContent = .init(
        html:
            "<table><caption>Control with hidden labels</caption><tr><th>Group</th><th>Score %</th></tr><tr><td>Masked</td><td>68</td></tr></table>",
        translationInput: ablation.text, mathematics: [:], mathDescriptions: [:])
    paper.blocks.append(ablation)
    paper.htmlReading = try await HTMLReadingStore().append(
        [.init(block: ablation, translation: nil)], to: paper.htmlReading, paper: paper, root: root)
    let memory = Evidence(
        id: "prior", title: "Replication notes", text: "Previously I wondered about copied labels.", paperID: UUID(),
        readingNoteID: UUID())
    let longBody = [
        "### 第 1 步：谁能看见标签？", "1. 判别者同时得到标签和前缀。\n2. 学习者只获得前缀。",
        String(repeating: "两种角色即便面对同一个前缀，也处于不同的信息条件。这个比较检验提示带来的作用，还不能判断学习者脱离提示后的迁移表现。\n\n", count: 15),
        "> 我的理解：若要分清提示暴露与真正迁移，可以在新的前缀上保持预算相同再测。", "同预算时是 74% 对 71%。",
    ].joined(separator: "\n\n")
    let answer = try await CloseReadingEngine.run(
        paper: paper, root: root, retrieveNotes: { _ in [memory] }, progress: { _ in },
        complete: { system, payload in
            if system.contains("最终综合") {
                #expect(system.contains("1,200–2,500") && system.contains("证据") && system.contains("竞争解释"))
                let input = try CloseReadingNotebookInput.read(payload)
                let own = try #require(input.sources.first { $0.quote == "The judge sees the label" })
                let observation = try #require(input.sources.first { $0.quote == "At matched budgets" })
                let prior = try #require(input.sources.first { $0.kind == "readingNote" })
                let table = try #require(input.sources.first { $0.kind == "table" })
                #expect(
                    table.tableRows?.contains("Masked\t68") == true
                        && !input.outlineEvidence.flatMap(\.sources).contains(table.id))
                #expect(observation.context?.contains("74%") == true && own.context?.contains("learner") == true)
                let sections: [[String: Any]] = [
                    [
                        "heading": "标签如何改变监督？（\(own.id)）", "markdown": longBody + "（\(own.id)、\(observation.id)）",
                        "sources": [own.id],
                    ],
                    [
                        "heading": "Q17 条件下的遮蔽对照", "markdown": "Q17 是论文定义的条件。遮住标签时报告了 68%。",
                        "sources": [own.id, table.id],
                    ],
                    [
                        "heading": "跨篇对照带来的问题", "markdown": "> 以前的笔记担心标签可能被抄录；本篇的输入设置使这个疑问值得检验。",
                        "sources": [prior.id, own.id],
                    ],
                    ["heading": "无依据的数字", "markdown": "准确率达到了 94%。", "sources": [observation.id]],
                    ["heading": "只有个人回忆", "markdown": "证明了本篇结论。", "sources": [prior.id]],
                    ["heading": "未登记的图", "markdown": "![[unseen.png]]", "sources": [own.id]],
                    ["heading": "未登记的出处", "markdown": "一个假设（Q99）。", "sources": [own.id]],
                ]
                return String(
                    decoding: try JSONSerialization.data(withJSONObject: [
                        "keep": ["N1", "N999"], "sections": sections,
                    ]),
                    as: UTF8.self)
            }
            return """
                {"annotations":[{"dimension":"method","source":"P1","quote":"The judge sees the label","analysis":"标签改变了判别者获得的信息。","references":[{"source":"L1","quote":"Previously I wondered about copied labels."}]}],
                 "outline":[{"stage":"evidence","text":"比较了相同预算下的结果。","references":[{"source":"P2","quote":"At matched budgets"}]}]}
                """
        })
    #expect(longBody.count > 720 && answer.sections.map(\.heading) == ["标签如何改变监督？", "Q17 条件下的遮蔽对照", "跨篇对照带来的问题"])
    #expect(answer.sections.first?.markdown == longBody)
    #expect(answer.sections.first?.references.map(\.quote) == ["The judge sees the label", "At matched budgets"])
    #expect(answer.sections.last?.references.first?.evidence.readingNoteID == memory.readingNoteID)
    #expect(answer.coverage.contains("4 节文末解读"))
    #expect(answer.sections[1].markdown.hasPrefix("Q17"))
}

private enum CloseReadingRepairOutcome: CaseIterable { case revised, disconnected, cancelled }

@Test(arguments: CloseReadingRepairOutcome.allCases)
private func closeReadingRepairsOnlyRejectedNumbersAndKeepsTheOtherSections(
    outcome: CloseReadingRepairOutcome
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = "Both models used the same budget. Alpha scored 38.1 and Beta scored 37.5."
    let paper = try await closeReadingFixture(root: root, texts: [source])
    let calls = CloseReadingAttempts()
    func read() async throws -> CloseReadingAnalysis {
        try await CloseReadingEngine.run(
            paper: paper, root: root, progress: { _ in },
            complete: { system, payload in
                if system.contains("局部数值订正") {
                    await calls.combine()
                    #expect(payload.contains("R1") && payload.contains("38.1") && !payload.contains("有效节标题"))
                    switch outcome {
                    case .revised:
                        return
                            #"{"revisions":[{"id":"R1","markdown":"同预算时，Alpha 为 38.1，Beta 为 37.5。模型记作 \\(q\\)，原样代码是 `\\(q\\)`。"}]}"#
                    case .disconnected: throw URLError(.notConnectedToInternet)
                    case .cancelled: throw CancellationError()
                    }
                }
                if system.contains("最终综合") {
                    return
                        #"{"keep":[],"sections":[{"heading":"对照能说明什么？","markdown":"差距为 0.6 分。","sources":["Q1"]},{"heading":"有效节标题","markdown":"两组预算相同，因此预算没有随模型变化。","sources":["Q1"]}]}"#
                }
                return
                    #"{"annotations":[],"outline":[{"stage":"evidence","text":"两组预算相同。","references":[{"source":"P1","quote":"Both models used the same budget."}]}]}"#
            })
    }
    if outcome == .cancelled {
        await #expect(throws: CancellationError.self) { try await read() }
    } else {
        let result = try await read()
        if outcome == .revised {
            #expect(result.sections.map(\.heading) == ["对照能说明什么？", "有效节标题"])
            #expect(result.sections.first?.markdown == #"同预算时，Alpha 为 38.1，Beta 为 37.5。模型记作 $q$，原样代码是 `\(q\)`。"#)
            #expect(!result.coverage.contains("未通过"))
        } else {
            #expect(result.sections.map(\.heading) == ["有效节标题"])
            #expect(result.coverage.contains("局部数值订正请求未完成") && result.coverage.contains("1 节文末解读未通过"))
        }
        #expect(result.sections.last?.references.first?.quote == "Both models used the same budget.")
    }
    #expect(await calls.synthesis == 1)
}

@Test func closeReadingTreatsTableAndFigureLabelsAsLocators() {
    let proof = "Table 6a reports a score of 9. Figure 2(b) plots the same observation."
    #expect(CloseReadingEngine.numbersAreGrounded("表 6(a) 和图2（b）均报告 9 分。", in: proof))
    #expect(!CloseReadingEngine.numbersAreGrounded("由表6(a)可见提升 6 分。", in: proof))
    #expect(!CloseReadingEngine.numbersAreGrounded("图6(a) 列有该结果。", in: proof))
    #expect(!CloseReadingEngine.numbersAreGrounded("表6(b) 列有该结果。", in: proof))
}

@Test func closeReadingSalvagesOnlyVerifiedUninterruptedParagraphPrefixes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let quote = "At the same budget, Alpha scored 38.1 and Beta scored 37.5 (Table 6a)."
    let paper = try await closeReadingFixture(root: root, texts: [quote])
    let result = try await CloseReadingEngine.run(
        paper: paper, root: root, progress: { _ in },
        complete: { system, _ in
            if system.contains("局部数值订正") {
                return
                    #"{"revisions":[{"id":"R2","markdown":"表6(a) 的两组预算一致。\n\nAlpha 为 38.1，Beta 为 37.5。\n\n原文未列的差距为 0.6。"}]}"#
            }
            if system.contains("最终综合") {
                return #"""
                    {"keep":[],"sections":[
                      {"heading":"同预算比较","markdown":"预算相同。\n\n差值为 0.6。\n\n不能拼接这里。","sources":["Q1"]},
                      {"heading":"改稿能多保留一段","markdown":"预算相同。\n\n差值为 0.6。","sources":["Q1"]},
                      {"heading":"超过 500 分","markdown":"预算相同。\n\n两组都很高。","sources":["Q1"]},
                      {"heading":"首段有误","markdown":"相差 0.6。\n\n预算相同。","sources":["Q1"]},
                      {"heading":"不能切开公式","markdown":"$$\nx。\n\ny=0.6\n$$\n\n预算相同。","sources":["Q1"]},
                      {"heading":"不能切开引用","markdown":"> Alpha 为 38.1。\n\n> 相差 0.6。","sources":["Q1"]},
                      {"heading":"不能切开代码","markdown":"```text\n第一段。\n\n0.6\n```","sources":["Q1"]}
                    ]}
                    """#
            }
            return
                #"{"annotations":[],"outline":[{"stage":"evidence","text":"预算相同。","references":[{"source":"P1","quote":"At the same budget"}]}]}"#
        })
    #expect(result.sections.map(\.markdown) == ["预算相同。", "表6(a) 的两组预算一致。\n\nAlpha 为 38.1，Beta 为 37.5。"])
    #expect(result.coverage.contains("2 节仅保留已核对段落"))
    #expect(result.coverage.contains("5 节文末解读未通过"))
}

@Test func notebookWritingDoesNotRemoveVerifiedMarginNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paper = try await closeReadingFixture(
        root: root,
        texts: [
            "The larger budget doubles the available routes.", "The held-out routes have equal budgets.",
        ])
    let result = try await CloseReadingEngine.run(
        paper: paper, root: root, progress: { _ in },
        complete: { _, input in
            if let window = try? JSONDecoder().decode(CloseReadingTestInput.self, from: Data(input.utf8)) {
                let rows = window.passages.enumerated().map { index, passage in
                    [
                        "source": passage.source, "quote": passage.anchorText, "dimension": "evidence",
                        "analysis": index == 0 ? "预算同时增加，因此不能分离策略的作用。" : "等预算比较能排除预算变化这种解释。",
                    ]
                }
                return String(
                    decoding: try JSONSerialization.data(withJSONObject: ["annotations": rows]), as: UTF8.self)
            }
            return #"{"keep":[],"sections":[{"heading":"预算改变了什么","markdown":"更高的预算提供更多可选路线。","sources":["Q1"]}]}"#
        })
    #expect(result.annotations.count == 2)
    #expect(result.sections.count == 1)
}

@Test func sparseMarginCoverageAndThinNotebookGetIndependentEvidencePasses() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let terms = ["budget", "rule", "baseline", "cohort", "control", "replication"]
    let paper = try await closeReadingFixture(
        root: root,
        texts: terms.map { term in
            "The " + term + " is recorded independently. "
                + String(repeating: "The effect depends on the comparison group. ", count: 5)
        })
    let result = try await CloseReadingEngine.run(
        paper: paper, root: root, progress: { _ in },
        complete: { system, input in
            if system.contains("只追加尚未展开") {
                return
                    #"{"sections":[{"heading":"还能排除哪种解释","markdown":"分组改变比较口径，固定比较组才能检验策略本身。","sources":["Q2","Q3"]}]}"#
            }
            if system.contains("最终综合") {
                return #"{"sections":[{"heading":"一句话概括","markdown":"可观察到的效果取决于比较组。","sources":["Q1"]}]}"#
            }
            let window = try JSONDecoder().decode(CloseReadingTestInput.self, from: Data(input.utf8))
            let extra = system.contains("本次只补读")
            if extra { #expect(!window.passages.contains { $0.source == "P1" }) }
            let records = window.passages.prefix(extra ? 4 : 1).map { passage in
                let quote = String(passage.anchorText.prefix { $0 != "." })
                return [
                    "source": passage.source, "quote": quote, "dimension": "method",
                    "analysis": quote + "。需要固定比较组以解释这项观察。",
                ]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["annotations": records]), as: UTF8.self)
        })
    #expect(result.annotations.count == 5)
    #expect(result.sections.map(\.heading) == ["一句话概括", "还能排除哪种解释"])
}
