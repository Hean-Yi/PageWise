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

/// Opt-in real-model toolchain probe. It uses a copy of the library and never writes the source.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_TEST_LIBRARY_TOOLS"] == "1"))
@MainActor func liveModelRunsTheMemoryToolchainOnACopiedRealLibrary() async throws {
    let environment = ProcessInfo.processInfo.environment
    let source = try #require(environment["PAGEWISE_TEST_LIBRARY"])
    let key = try #require(environment["PAGEWISE_TEST_SLEEP_KEY"])
    let sourceRoot = URL(fileURLWithPath: source, isDirectory: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: sourceRoot.appendingPathComponent("library.sqlite"), to: root.appendingPathComponent("library.sqlite"))
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    var settings = ModelSettings()
    settings.baseURL = "https://api.deepseek.com"
    settings.model = "deepseek-flash"
    _ = try reader.saveSettings(settings, key: key)

    let oldID: UUID
    if let chat = reader.state.chats.first {
        let old = MemoryItem(text: MemoryItem.automaticPrefix + "旧的吞吐量比较记录", sourceID: chat.id)
        oldID = old.id
        reader.state.memories = [old]
        _ = await reader.save()
    } else {
        throw ReaderError.message("复制书库中没有可用于来源的对话。")
    }

    func limits(_ names: Set<String>) -> AgentLimits {
        var limits = AgentLimits()
        limits.availableToolNames = names
        return limits
    }
    let proposeAgent = LibraryAgent(
        reader: reader, client: AgentClient(), limits: limits(["propose_memory"]))
    proposeAgent.send(
        "请使用 propose_memory 把「我长期关注等计算预算下的方法比较」记为待核实研究记忆；只使用这个工具。")
    for _ in 0..<240 where proposeAgent.isRunning { try await Task.sleep(for: .milliseconds(250)) }
    print("LIVE_TOOLCHAIN_PROPOSE", proposeAgent.turns.last?.activities.map { "\($0.toolName):\($0.status)" } ?? [])
    let proposed = try #require(
        reader.state.memories.first { !$0.deleted && $0.text.contains("等计算预算") })

    let reviseAgent = LibraryAgent(
        reader: reader, client: AgentClient(), limits: limits(["revise_memory"]))
    reviseAgent.send(
        "请使用 revise_memory，memory_id=\(proposed.id.uuidString)，把这条记忆改成「只关注匹配训练时长」。")
    for _ in 0..<240 where reviseAgent.isRunning { try await Task.sleep(for: .milliseconds(250)) }
    print("LIVE_TOOLCHAIN_REVISE", reviseAgent.turns.last?.activities.map { "\($0.toolName):\($0.status)" } ?? [])

    let forgetAgent = LibraryAgent(
        reader: reader, client: AgentClient(), limits: limits(["forget_memory"]))
    forgetAgent.send("请使用 forget_memory，memory_id=\(oldID.uuidString)，忘掉旧的吞吐量记录。")
    for _ in 0..<240 where forgetAgent.isRunning { try await Task.sleep(for: .milliseconds(250)) }
    print(
        "LIVE_TOOLCHAIN_FORGET", forgetAgent.turns.last?.activities.map { "\($0.toolName):\($0.status)" } ?? [],
        "memories", reader.state.memories.map { "\($0.deleted):\($0.text)" })
    #expect(
        proposeAgent.turns.last?.activities.contains { $0.toolName == "propose_memory" && $0.status == .succeeded }
            == true)
    #expect(
        reviseAgent.turns.last?.activities.contains { $0.toolName == "revise_memory" && $0.status == .succeeded }
            == true)
    #expect(
        forgetAgent.turns.last?.activities.contains { $0.toolName == "forget_memory" && $0.status == .succeeded }
            == true)
    #expect(reader.state.memories.contains { $0.text.contains("训练时长") && !$0.deleted })
    #expect(reader.state.memories.contains { $0.deleted && $0.text.isEmpty })
}

/// Opt-in natural tool-selection probe with the full catalog. It reports what the model chose;
/// it intentionally does not force a particular tool.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_TEST_LIBRARY_UNCONSTRAINED"] == "1"))
@MainActor func liveModelChoosesMemoryToolsWithoutAForcedCatalog() async throws {
    let environment = ProcessInfo.processInfo.environment
    let source = try #require(environment["PAGEWISE_TEST_LIBRARY"])
    let key = try #require(environment["PAGEWISE_TEST_SLEEP_KEY"])
    let sourceRoot = URL(fileURLWithPath: source, isDirectory: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: sourceRoot.appendingPathComponent("library.sqlite"), to: root.appendingPathComponent("library.sqlite"))
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    var settings = ModelSettings()
    settings.baseURL = "https://api.deepseek.com"
    settings.model = "deepseek-flash"
    _ = try reader.saveSettings(settings, key: key)
    if let chat = reader.state.chats.first {
        reader.state.memories = [
            MemoryItem(text: MemoryItem.automaticPrefix + "旧的吞吐量比较记录", sourceID: chat.id)
        ]
        _ = await reader.save()
    }
    let agent = LibraryAgent(reader: reader, client: AgentClient())
    let questions = [
        "我在研究等计算预算下的方法比较，请记住这个研究方向。",
        "更正一下：我现在只关注匹配训练时长，而不是只看预算。",
        "忘掉之前关于吞吐量的旧记录。",
    ]
    for question in questions {
        agent.send(question)
        for _ in 0..<240 where agent.isRunning {
            try await Task.sleep(for: .milliseconds(250))
        }
        print(
            "LIVE_UNCONSTRAINED",
            agent.turns.last?.activities.map { "\($0.toolName):\($0.status):\($0.message ?? "")" } ?? [],
            "answer", agent.turns.last?.answer ?? "")
    }
    #expect(agent.turns.count == questions.count)
    let activities = agent.turns.flatMap(\.activities)
    #expect(
        activities.contains { $0.toolName == "propose_memory" && $0.status == .succeeded })
    #expect(
        activities.contains { $0.toolName == "revise_memory" && $0.status == .succeeded })
    #expect(
        activities.contains { $0.toolName == "forget_memory" && $0.status == .succeeded })
}
