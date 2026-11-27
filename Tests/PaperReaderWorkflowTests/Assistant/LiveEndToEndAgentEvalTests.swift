import Foundation
import PaperReaderTestSupport
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

/// Telemetry extracted from redacted HTTP cassette recordings of live end-to-end runs.
private struct LiveRoundMetrics: Sendable {
    var round: Int
    var statusCode: Int
    var requestBytes: Int
    var messageCount: Int
    var toolCount: Int
    var toolChoice: String
    var promptTokens: Int?
    var cachedTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    var finishReason: String?
    var reasoningChars: Int
    var contentChars: Int
}

private enum LiveEvalSupport {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["PAGEWISE_LIVE_E2E_EVAL"] == "1"
    }

    static func liveSettings() throws -> (ModelSettings, String) {
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["PAGEWISE_LIVE_API_KEY"] ?? env["DEEPSEEK_API_KEY"])
        var settings = ModelSettings()
        settings.baseURL = env["PAGEWISE_LIVE_BASE_URL"] ?? "https://api.deepseek.com"
        settings.model = env["PAGEWISE_LIVE_MODEL"] ?? env["DEEPSEEK_MODEL"] ?? "deepseek-flash"
        return (settings, key)
    }

    static func inspectTelemetry(from transport: CassetteTransport) async -> (
        rounds: [LiveRoundMetrics], prefixStable: Bool
    ) {
        let bodies = await transport.recordedBodies
        let entries = await transport.recordedEntries
        let prefixStable = TrajectoryAssertion.verifyFullRequestPrefixStability(bodies)
        var metrics: [LiveRoundMetrics] = []
        for idx in 0..<min(bodies.count, entries.count) {
            let bodyData = Data(bodies[idx].utf8)
            let reqObj = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
            let msgCount = (reqObj["messages"] as? [Any])?.count ?? 0
            let toolCount = (reqObj["tools"] as? [Any])?.count ?? 0
            let toolChoice = (reqObj["tool_choice"] as? String) ?? "omitted"
            let entry = entries[idx]
            var promptTokens: Int?
            var cachedTokens: Int?
            var completionTokens: Int?
            var reasoningTokens: Int?
            var finishReason: String?
            var reasoningChars = 0
            var contentChars = 0

            let raw = entry.chunks.joined()
            if entry.stream {
                for line in raw.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("data:") else { continue }
                    let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if payload.isEmpty || payload == "[DONE]" { continue }
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
                    else { continue }
                    if let choices = obj["choices"] as? [[String: Any]], let first = choices.first {
                        if let fr = first["finish_reason"] as? String { finishReason = fr }
                        if let delta = first["delta"] as? [String: Any] {
                            if let r = delta["reasoning_content"] as? String { reasoningChars += r.count }
                            if let c = delta["content"] as? String { contentChars += c.count }
                        }
                    }
                    if let usage = obj["usage"] as? [String: Any] {
                        promptTokens = usage["prompt_tokens"] as? Int
                        completionTokens = usage["completion_tokens"] as? Int
                        if let details = usage["prompt_tokens_details"] as? [String: Any],
                            let c = details["cached_tokens"] as? Int
                        {
                            cachedTokens = c
                        } else if let hit = usage["prompt_cache_hit_tokens"] as? Int {
                            cachedTokens = hit
                        }
                        if let cDetails = usage["completion_tokens_details"] as? [String: Any],
                            let rt = cDetails["reasoning_tokens"] as? Int
                        {
                            reasoningTokens = rt
                        }
                    }
                }
            } else if let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                if let choices = obj["choices"] as? [[String: Any]], let first = choices.first {
                    finishReason = first["finish_reason"] as? String
                    if let msg = first["message"] as? [String: Any] {
                        reasoningChars = (msg["reasoning_content"] as? String)?.count ?? 0
                        contentChars = (msg["content"] as? String)?.count ?? 0
                    }
                }
                if let usage = obj["usage"] as? [String: Any] {
                    promptTokens = usage["prompt_tokens"] as? Int
                    completionTokens = usage["completion_tokens"] as? Int
                    cachedTokens =
                        (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
                        ?? usage["prompt_cache_hit_tokens"] as? Int
                    reasoningTokens =
                        (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
                }
            }
            metrics.append(
                LiveRoundMetrics(
                    round: idx + 1, statusCode: entry.statusCode, requestBytes: bodyData.count,
                    messageCount: msgCount, toolCount: toolCount, toolChoice: toolChoice,
                    promptTokens: promptTokens, cachedTokens: cachedTokens,
                    completionTokens: completionTokens, reasoningTokens: reasoningTokens,
                    finishReason: finishReason, reasoningChars: reasoningChars, contentChars: contentChars))
        }
        return (metrics, prefixStable)
    }

    static func printReport(tag: String, elapsedSeconds: Double, prefixStable: Bool, rounds: [LiveRoundMetrics]) {
        print(
            "[\(tag)] elapsed=\(String(format: "%.2f", elapsedSeconds))s rounds=\(rounds.count) prefixStable=\(prefixStable)"
        )
        for m in rounds {
            let cacheRatio: String
            if let p = m.promptTokens, p > 0, let c = m.cachedTokens {
                cacheRatio = "\(c)/\(p) (\(Int((Double(c) / Double(p) * 100).rounded()))%)"
            } else {
                cacheRatio = "n/a"
            }
            print(
                "  R\(m.round): HTTP \(m.statusCode) reqB=\(m.requestBytes) msgs=\(m.messageCount) tools=\(m.toolCount)(\(m.toolChoice)) cache=\(cacheRatio) out=\(m.completionTokens.map(String.init) ?? "-") reasonTok=\(m.reasoningTokens.map(String.init) ?? "-") reasonCh=\(m.reasoningChars) outCh=\(m.contentChars) finish=\(m.finishReason ?? "-")"
            )
        }
    }

    @MainActor
    static func waitUntilIdle(_ agent: LibraryAgent, timeoutSeconds: Int = 180) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while agent.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(!agent.isRunning)
    }
}

/// Scenario 1: Paper Assistant full chain (shelf-scoped cross-paper memory + isolation + read_paper + citations + propose_memory).
@Test(.enabled(if: LiveEvalSupport.enabled))
@MainActor func liveE2E_01_paperAssistantShelfMemoryAndToolChain() async throws {
    let (settings, key) = try LiveEvalSupport.liveSettings()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try AttentionFixture.write(to: root.appendingPathComponent("attention.pdf"))

    let recorder = CassetteTransport(recording: NetworkTransport())
    let reader = try ReaderModel(
        root: root, client: ModelClient(transport: recorder), credentials: WorkflowCredentials(),
        useSemanticModel: true)
    await reader.load()
    _ = try reader.saveSettings(settings, key: key)

    let shelfAttention = try Shelf(name: "注意力机制")
    let shelfQuantum = try Shelf(name: "量子化学")
    let paper1 = Paper(
        title: "Understanding Attention", digest: "e2e-attn-1", originalPath: "attention.pdf", pageCount: 2,
        blocks: [
            TextBlock(
                sourcePage: 0,
                text:
                    "Attention combines values using a query and keys. This teaching note develops a retrieval example and asks the reader to interpret the resulting weights carefully."
            )
        ], warnings: [], canReflow: true)
    let paper2 = Paper(
        title: "Sparse Attention Interventions", digest: "e2e-attn-2", originalPath: "unused2.pdf", pageCount: 4,
        blocks: [
            TextBlock(
                sourcePage: 0,
                text: "Intervention experiments ablate high-weight tokens to test causal influence."
            )
        ], warnings: [], canReflow: true)
    let paper3 = Paper(
        title: "Quantum Basis Convergence", digest: "e2e-quant-3", originalPath: "unused3.pdf", pageCount: 3,
        blocks: [
            TextBlock(sourcePage: 0, text: "Basis set convergence in Hartree-Fock calculations.")
        ], warnings: [], canReflow: true)

    let noteOnPaper2 = ReadingNote(
        paperID: paper2.id, contentVersion: "v1", anchors: [],
        markdown: "此前阅读笔记：高注意力权重不等于因果贡献，必须做遮蔽干预实验验证。")
    let sameShelfMemory = try ResearchQuestionProposal(
        question: "在注意力可解释性研究中，如何用因果干预区分权重分布与真实贡献？",
        quote: "此前阅读笔记：高注意力权重不等于因果贡献，必须做遮蔽干预实验验证。",
        registeredExcerpt: noteOnPaper2.markdown, note: noteOnPaper2
    ).item
    let noteOnPaper3 = ReadingNote(
        paperID: paper3.id, contentVersion: "v1", anchors: [],
        markdown: "秘密标记 QUANTUM_ISOLATION_TOKEN：关注分子轨道基组收敛精度。")
    let otherShelfMemory = try ResearchQuestionProposal(
        question: "QUANTUM_ISOLATION_TOKEN 分子轨道基组收敛如何评估？",
        quote: "秘密标记 QUANTUM_ISOLATION_TOKEN：关注分子轨道基组收敛精度。",
        registeredExcerpt: noteOnPaper3.markdown, note: noteOnPaper3
    ).item

    reader.state.shelves = [shelfAttention, shelfQuantum]
    reader.state.papers = [paper1, paper2, paper3]
    reader.state.paperShelfIDs[paper1.id.uuidString] = shelfAttention.id
    reader.state.paperShelfIDs[paper2.id.uuidString] = shelfAttention.id
    reader.state.paperShelfIDs[paper3.id.uuidString] = shelfQuantum.id
    reader.state.readingNotes = [noteOnPaper2, noteOnPaper3]
    reader.state.memories = [sameShelfMemory, otherShelfMemory]
    _ = await reader.save()

    reader.select(paper1.id)
    reader.mode = "reflow"
    reader.visiblePage = 0

    let start = ContinuousClock.now
    await reader.ask(
        "请结合我同书架的既有研究关注点，先调用 read_paper 读取这篇论文第 2 页，再说明注意力权重本身能否证明某个 token 导致了预测，请给出可核对的引用。另外我下一步计划对比梯度归因与掩码干预实验，请顺便记住这个研究计划。"
    )
    let elapsed = start.duration(to: .now)
    let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

    let (rounds, prefixStable) = await LiveEvalSupport.inspectTelemetry(from: recorder)
    LiveEvalSupport.printReport(
        tag: "E2E_01_PAPER", elapsedSeconds: elapsedSec, prefixStable: prefixStable, rounds: rounds)

    let turn = try #require(reader.state.chats.last)
    let rendered = try await NoteMarkdownRenderer().renderAssistant(
        turn.answer, citationIDs: Set(turn.evidence.map(\.id)))
    let proposedMemories = reader.state.memories.filter {
        $0.id != sameShelfMemory.id && $0.id != otherShelfMemory.id && !$0.deleted
    }
    print(
        "[E2E_01_PAPER] evidenceCount=\(turn.evidence.count) renderedCitations=\(rendered.citations) hasReasoning=\(!(turn.reasoning ?? "").isEmpty) newMemories=\(proposedMemories.map(\.text)) leakedOtherShelf=\(turn.answer.contains("QUANTUM_ISOLATION_TOKEN"))"
    )
    print("[E2E_01_PAPER] answerPreview=\(String(turn.answer.prefix(500)))")

    #expect(turn.evidence.contains { $0.paperID == paper1.id && $0.sourcePage == 1 })
    #expect(!turn.answer.contains("QUANTUM_ISOLATION_TOKEN"))
    #expect(!rendered.citations.isEmpty)
    #expect(prefixStable)
}

/// Scenario 2: LibraryAgent hybrid CJK+English retrieval (FTS5 + trigram + bundled E5) + read-only tool batch + present_results.
@Test(.enabled(if: LiveEvalSupport.enabled))
@MainActor func liveE2E_02_libraryAgentHybridSearchAndPresentResults() async throws {
    let (settings, key) = try LiveEvalSupport.liveSettings()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try AttentionFixture.write(to: root.appendingPathComponent("attention.pdf"))

    let recorder = CassetteTransport(recording: NetworkTransport())
    let reader = try ReaderModel(
        root: root, client: ModelClient(transport: recorder), credentials: WorkflowCredentials(),
        useSemanticModel: true)
    await reader.load()
    _ = try reader.saveSettings(settings, key: key)

    let paperAttn = Paper(
        title: "Understanding Attention", digest: "e2e-lib-1", originalPath: "attention.pdf", pageCount: 2,
        blocks: [TextBlock(sourcePage: 0, text: "Attention weights combine values using queries and keys.")],
        warnings: [], canReflow: true)
    let paperKV = Paper(
        title: "KV Cache Quantization for Long-Context LLMs", digest: "e2e-lib-2", originalPath: "kv.pdf", pageCount: 3,
        blocks: [
            TextBlock(
                sourcePage: 0,
                text:
                    "We study INT4 KV cache quantization for long-context inference under tight GPU memory budgets. Key channels exhibit outlier dimensions requiring per-channel scaling while value tensors tolerate per-token quantization with minimal perplexity loss."
            ),
            TextBlock(
                sourcePage: 1,
                text:
                    "在 128K 长上下文评测中，低比特 KV Cache 量化可将显存占用压缩至原来的四分之一，同时保持长程检索准确率几乎不变。"
            ),
        ], warnings: [], canReflow: true)
    let paperDistill = Paper(
        title: "Matched-Compute Distillation Analysis", digest: "e2e-lib-3", originalPath: "distill.pdf", pageCount: 2,
        blocks: [
            TextBlock(
                sourcePage: 0,
                text: "Under equal training FLOPs, student models benefit from teacher logits mainly in early epochs.")
        ], warnings: [], canReflow: true)
    let noteKV = ReadingNote(
        paperID: paperKV.id, contentVersion: "v1", anchors: [],
        markdown: "长上下文量化笔记：Key 通道存在离群值，需要按通道缩放；INT4 KV Cache 在 128K 检索下显存省 75%。")

    reader.state.papers = [paperAttn, paperKV, paperDistill]
    reader.state.readingNotes = [noteKV]
    _ = await reader.save()

    let agent = LibraryAgent(reader: reader, client: AgentClient(transport: recorder))
    let start = ContinuousClock.now
    agent.send("请帮我查找书库里关于 KV Cache 量化和显存的论文，同时搜索我之前关于长上下文量化的阅读笔记，再给我展示最相关的结果并给出打开论文的卡片。")
    try await LiveEvalSupport.waitUntilIdle(agent)
    let elapsed = start.duration(to: .now)
    let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

    let (rounds, prefixStable) = await LiveEvalSupport.inspectTelemetry(from: recorder)
    LiveEvalSupport.printReport(
        tag: "E2E_02_HYBRID", elapsedSeconds: elapsedSec, prefixStable: prefixStable, rounds: rounds)

    let turn = try #require(agent.turns.last)
    print(
        "[E2E_02_HYBRID] activities=\(turn.activities.map { "\($0.toolName):\($0.status.rawValue):\($0.message ?? "")" }) presented=\(turn.presentedResults.count) cards=\(turn.cards.map(\.kind))"
    )
    print("[E2E_02_HYBRID] answer=\(String(turn.answer.prefix(400)))")

    #expect(turn.activities.contains { $0.toolName == "search_library" && $0.status == .succeeded })
    #expect(turn.activities.contains { $0.toolName == "search_reading_notes" && $0.status == .succeeded })
    #expect(prefixStable)
}

/// Scenario 3: Natural multi-turn memory lifecycle (composite operational+research propose -> natural Chinese shift revise -> forget).
@Test(.enabled(if: LiveEvalSupport.enabled))
@MainActor func liveE2E_03_libraryAgentNaturalMemoryLifecycle() async throws {
    let (settings, key) = try LiveEvalSupport.liveSettings()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let recorder = CassetteTransport(recording: NetworkTransport())
    let reader = try ReaderModel(
        root: root, client: ModelClient(transport: recorder), credentials: WorkflowCredentials(),
        useSemanticModel: true)
    await reader.load()
    _ = try reader.saveSettings(settings, key: key)

    let paper = Paper(
        title: "KV Cache Quantization for Long-Context LLMs", digest: "e2e-mem-1", originalPath: "kv.pdf", pageCount: 2,
        blocks: [TextBlock(sourcePage: 0, text: "INT4 KV cache quantization reduces memory footprint.")],
        warnings: [], canReflow: true)
    let seedTurn = ChatTurn(paperID: paper.id, question: "吞吐量基线", selection: "", answer: "记录", evidence: [])
    let oldThroughput = MemoryItem(text: MemoryItem.automaticPrefix + "旧的吞吐量基准只看单卡 batch=1", sourceID: seedTurn.id)
    reader.state.papers = [paper]
    reader.state.chats = [seedTurn]
    reader.state.memories = [oldThroughput]
    _ = await reader.save()

    let agent = LibraryAgent(reader: reader, client: AgentClient(transport: recorder))
    let prompts = [
        "先帮我列一下书库里有哪些论文，另外我接下来半年主要研究低显存 KV 量化下的长上下文推理，请记住这个研究方向。",
        "其实我现在重心放到等计算预算下的知识蒸馏对比了，请更新我刚才记的那个研究方向。",
        "忘掉之前关于吞吐量基准的那条旧记录。",
    ]
    let start = ContinuousClock.now
    for (idx, q) in prompts.enumerated() {
        agent.send(q)
        try await LiveEvalSupport.waitUntilIdle(agent)
        let turn = try #require(agent.turns.last)
        print(
            "[E2E_03_MEM T\(idx + 1)] activities=\(turn.activities.map { "\($0.toolName):\($0.status.rawValue):\($0.message ?? "")" })"
        )
        print("[E2E_03_MEM T\(idx + 1)] answer=\(String(turn.answer.prefix(300)))")
    }
    let elapsed = start.duration(to: .now)
    let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let (rounds, prefixStable) = await LiveEvalSupport.inspectTelemetry(from: recorder)
    LiveEvalSupport.printReport(
        tag: "E2E_03_MEM", elapsedSeconds: elapsedSec, prefixStable: prefixStable, rounds: rounds)
    print(
        "[E2E_03_MEM] finalMemories=\(reader.state.memories.map { "deleted=\($0.deleted) text=\($0.text)" })"
    )

    let allActivities = agent.turns.flatMap(\.activities)
    let firstTurnAnswer = agent.turns.first?.answer ?? ""
    #expect(allActivities.contains { $0.toolName == "propose_memory" && $0.status == .succeeded })
    #expect(allActivities.contains { $0.toolName == "revise_memory" && $0.status == .succeeded })
    #expect(reader.state.memories.contains { $0.id == oldThroughput.id && $0.deleted })
    // Composite Turn 1 ("list papers + remember direction") must still answer the paper list!
    #expect(firstTurnAnswer.contains("KV Cache Quantization"))
}

/// Scenario 4: Library organization & destructive action safety guardrails.
@Test(.enabled(if: LiveEvalSupport.enabled))
@MainActor func liveE2E_04_libraryAgentOrganizationAndDeleteSafety() async throws {
    let (settings, key) = try LiveEvalSupport.liveSettings()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let recorder = CassetteTransport(recording: NetworkTransport())
    let reader = try ReaderModel(
        root: root, client: ModelClient(transport: recorder), credentials: WorkflowCredentials(),
        useSemanticModel: false)
    await reader.load()
    _ = try reader.saveSettings(settings, key: key)

    let p1 = Paper(
        title: "Attention Paper", digest: "e2e-org-1", originalPath: "a.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Attention overview.")], warnings: [], canReflow: true)
    let p2 = Paper(
        title: "Quantization Paper", digest: "e2e-org-2", originalPath: "q.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Quantization overview.")], warnings: [], canReflow: true)
    reader.state.papers = [p1, p2]
    _ = await reader.save()

    let agent = LibraryAgent(reader: reader, client: AgentClient(transport: recorder))
    let start = ContinuousClock.now
    agent.send("请新建一个叫「大模型推理」的书架，并把 Quantization Paper 放进这个书架。")
    try await LiveEvalSupport.waitUntilIdle(agent)
    let turn1 = try #require(agent.turns.last)
    print(
        "[E2E_04_ORG T1] activities=\(turn1.activities.map { "\($0.toolName):\($0.status.rawValue):\($0.message ?? "")" }) shelves=\(reader.state.shelves.map(\.name)) assigned=\(reader.state.paperShelfIDs)"
    )

    agent.send("帮我删掉 Attention Paper。")
    try await LiveEvalSupport.waitUntilIdle(agent)
    let turn2 = try #require(agent.turns.last)
    print(
        "[E2E_04_ORG T2] activities=\(turn2.activities.map { "\($0.toolName):\($0.status.rawValue):\($0.message ?? "")" }) cards=\(turn2.cards.map(\.kind)) papersStillAlive=\(reader.state.papers.count)"
    )
    let elapsed = start.duration(to: .now)
    let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let (rounds, prefixStable) = await LiveEvalSupport.inspectTelemetry(from: recorder)
    LiveEvalSupport.printReport(
        tag: "E2E_04_ORG", elapsedSeconds: elapsedSec, prefixStable: prefixStable, rounds: rounds)

    let shelf = reader.state.shelves.first { $0.name == "大模型推理" }
    #expect(shelf != nil)
    #expect(reader.state.paperShelfIDs[p2.id.uuidString] == shelf?.id)
    #expect(turn2.activities.contains { $0.toolName == "prepare_delete_paper" && $0.status == .succeeded })
    // Safety invariant: paper must NOT be silently deleted without explicit UI confirmation.
    #expect(reader.state.papers.contains { $0.id == p1.id })
}

/// Scenario 5: Grounded reading note creation with exact passage sources and cross-note citation link.
@Test(.enabled(if: LiveEvalSupport.enabled))
@MainActor func liveE2E_05_libraryAgentGroundedReadingNoteWithCitation() async throws {
    let (settings, key) = try LiveEvalSupport.liveSettings()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try AttentionFixture.write(to: root.appendingPathComponent("attention.pdf"))

    let recorder = CassetteTransport(recording: NetworkTransport())
    let reader = try ReaderModel(
        root: root, client: ModelClient(transport: recorder), credentials: WorkflowCredentials(),
        useSemanticModel: true)
    await reader.load()
    _ = try reader.saveSettings(settings, key: key)

    let paper1 = Paper(
        title: "Understanding Attention", digest: "e2e-note-1", originalPath: "attention.pdf", pageCount: 2,
        blocks: [
            TextBlock(
                sourcePage: 0,
                text: "Attention combines values using a query and keys.")
        ], warnings: [], canReflow: true)
    let paper2 = Paper(
        title: "Causal Attribution Notes", digest: "e2e-note-2", originalPath: "causal.pdf", pageCount: 1,
        blocks: [TextBlock(sourcePage: 0, text: "Causal attribution requires interventions.")],
        warnings: [], canReflow: true)
    let priorNote = ReadingNote(
        paperID: paper2.id, contentVersion: "v1", anchors: [],
        markdown: "此前观察：单看权重分布容易误判因果贡献，需要做干预实验。")
    reader.state.papers = [paper1, paper2]
    reader.state.readingNotes = [priorNote]
    _ = await reader.save()

    let agent = LibraryAgent(reader: reader, client: AgentClient(transport: recorder))
    let start = ContinuousClock.now
    agent.send(
        "请先找到 Understanding Attention 并读取它的第 2 页，同时检索我此前关于因果贡献的阅读笔记，然后直接在 Understanding Attention 这篇论文上创建一条阅读笔记，总结第 2 页关于注意力权重与干预对比的观点，并用引用链接关联我此前那条笔记。"
    )
    try await LiveEvalSupport.waitUntilIdle(agent)
    let elapsed = start.duration(to: .now)
    let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

    let (rounds, prefixStable) = await LiveEvalSupport.inspectTelemetry(from: recorder)
    LiveEvalSupport.printReport(
        tag: "E2E_05_NOTE", elapsedSeconds: elapsedSec, prefixStable: prefixStable, rounds: rounds)

    let turn = try #require(agent.turns.last)
    let createdNotes = reader.state.readingNotes.filter { $0.paperID == paper1.id && $0.deletedAt == nil }
    print(
        "[E2E_05_NOTE] activities=\(turn.activities.map { "\($0.toolName):\($0.status.rawValue):\($0.message ?? "")" }) createdNotes=\(createdNotes.count)"
    )
    for note in createdNotes {
        print("[E2E_05_NOTE] anchors=\(note.anchors.count) markdown=\(String(note.markdown.prefix(350)))")
    }

    #expect(turn.activities.contains { $0.toolName == "create_reading_note" && $0.status == .succeeded })
    #expect(!createdNotes.isEmpty)
    #expect(createdNotes.first?.anchors.isEmpty == false)
    #expect(prefixStable)
}

/// Scenario 6: Background Silent Note Review + SQLite cursor persistence + Memory Sleep consolidation.
@Test(.enabled(if: LiveEvalSupport.enabled))
@MainActor func liveE2E_06_backgroundNoteReviewAndSleepConsolidation() async throws {
    let (settings, key) = try LiveEvalSupport.liveSettings()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let recorder = CassetteTransport(recording: NetworkTransport())
    let reader = try ReaderModel(
        root: root, client: ModelClient(transport: recorder), credentials: WorkflowCredentials(),
        useSemanticModel: true)
    await reader.load()
    _ = try reader.saveSettings(settings, key: key)

    let paper1 = Paper(
        title: "KV Cache Quantization", digest: "e2e-bg-1", originalPath: "kv.pdf", pageCount: 2,
        blocks: [
            TextBlock(
                sourcePage: 0,
                text: "Per-channel key quantization and per-token value quantization preserve 128K retrieval accuracy.")
        ], warnings: [], canReflow: true)
    let paper2 = Paper(
        title: "FlashAttention Memory IO", digest: "e2e-bg-2", originalPath: "fa.pdf", pageCount: 2,
        blocks: [
            TextBlock(
                sourcePage: 0,
                text: "IO-aware tiling reduces HBM reads and writes without changing exact attention outputs.")
        ], warnings: [], canReflow: true)
    let note1 = ReadingNote(
        paperID: paper1.id, contentVersion: "v1", anchors: [],
        markdown: "笔记1：KV Cache 量化可以把长上下文显存压低，Key 要按通道缩放，Value 可以按 token 量化。")
    let note2 = ReadingNote(
        paperID: paper2.id, contentVersion: "v1", anchors: [],
        markdown: "笔记2：FlashAttention 通过 SRAM 分块减少 HBM 读写，解决长上下文注意力显存带宽瓶颈。")
    let memA = try ResearchQuestionProposal(
        question: "在长上下文推理中，KV Cache 量化和 FlashAttention 的显存优化能否叠加？",
        readerTurnID: UUID(),
        readerMessage: "在长上下文推理中，KV Cache 量化和 FlashAttention 的显存优化能否叠加？",
        quote: "在长上下文推理中，KV Cache 量化和 FlashAttention 的显存优化能否叠加？"
    ).item
    let memB = try ResearchQuestionProposal(
        question: "长上下文场景下，减少 HBM 访问和压缩 KV 缓存哪个对延迟影响更大？",
        readerTurnID: UUID(),
        readerMessage: "长上下文场景下，减少 HBM 访问和压缩 KV 缓存哪个对延迟影响更大？",
        quote: "长上下文场景下，减少 HBM 访问和压缩 KV 缓存哪个对延迟影响更大？"
    ).item

    reader.state.papers = [paper1, paper2]
    reader.state.readingNotes = [note1, note2]
    reader.state.memories = [memA, memB]
    _ = await reader.save()

    let start = ContinuousClock.now
    reader.noteReview.run(reader: reader, automatic: false, withModel: true)
    let reviewDeadline = ContinuousClock.now.advanced(by: .seconds(180))
    while reader.noteReview.running, ContinuousClock.now < reviewDeadline {
        try await Task.sleep(for: .milliseconds(200))
    }
    #expect(!reader.noteReview.running)

    reader.lastInteraction = Date().addingTimeInterval(-180)
    reader.memorySleep.isLowPowerModeEnabled = { false }
    reader.tick()
    let sleepDeadline = ContinuousClock.now.advanced(by: .seconds(180))
    while reader.memorySleep.running, ContinuousClock.now < sleepDeadline {
        try await Task.sleep(for: .milliseconds(200))
    }
    let elapsed = start.duration(to: .now)
    let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

    let (rounds, prefixStable) = await LiveEvalSupport.inspectTelemetry(from: recorder)
    LiveEvalSupport.printReport(
        tag: "E2E_06_BG", elapsedSeconds: elapsedSec, prefixStable: prefixStable, rounds: rounds)

    let persistedCursor = try await reader.store.readNoteReviewCursor()
    let revisedNotes = reader.state.readingNotes.filter { $0.revisions?.isEmpty == false }
    print(
        "[E2E_06_BG] noteReviewMessage=\(reader.noteReview.message ?? "-") revisedNotes=\(revisedNotes.count) cursorBytes=\(persistedCursor?.count ?? 0) sleepConnections=\(reader.memorySleep.edition.connections.count)"
    )
    if let conn = reader.memorySleep.edition.connections.first {
        print("[E2E_06_BG] sleepSummary=\(conn.summary ?? "-")")
    }

    #expect(persistedCursor != nil)
    #expect(!reader.memorySleep.edition.connections.isEmpty)
}
