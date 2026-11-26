import Foundation
import PaperReaderTestSupport
import Testing

@testable import PaperReaderKit
@testable import PaperReaderUI

/// Opt-in real-model probe for the paper assistant's `read_paper` tool loop. It uses a copied
/// public teaching PDF and a synthetic one-page index, so the second page is only available
/// through the tool.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_TEST_PAPER_READ_TOOL"] == "1"))
@MainActor func livePaperAssistantReadsAnUnindexedPageThroughTheTool() async throws {
    let key = try #require(ProcessInfo.processInfo.environment["PAGEWISE_TEST_PAPER_READ_KEY"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try AttentionFixture.write(to: root.appendingPathComponent("fixture.pdf"))
    let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
    await reader.load()
    var settings = ModelSettings()
    settings.baseURL = "https://api.deepseek.com"
    settings.model = "deepseek-flash"
    _ = try reader.saveSettings(settings, key: key)
    let paper = Paper(
        title: "Understanding Attention", digest: "live-attention", originalPath: "fixture.pdf", pageCount: 2,
        blocks: [
            TextBlock(
                sourcePage: 0,
                text:
                    "Attention combines values using a query and keys. This teaching note develops a retrieval example and asks the reader to interpret the resulting weights carefully."
            )
        ], warnings: [], canReflow: true)
    reader.state.papers = [paper]
    reader.select(paper.id)
    reader.mode = "reflow"
    reader.visiblePage = 0
    await reader.ask("请先调用 read_paper 读取这篇论文第 2 页，再根据第 2 页说明：注意力权重本身是否能证明某个 token 导致了预测？请给出可核对的原页引用。")
    let turn = try #require(reader.state.chats.last)
    print("LIVE_PAPER_READ", turn.answer, turn.evidence.map { "\($0.id):\($0.sourcePage.map(String.init) ?? "-")" })
    #expect(turn.evidence.contains { $0.paperID == paper.id && $0.sourcePage == 1 })
    #expect(turn.answer.contains("[S"))
}
