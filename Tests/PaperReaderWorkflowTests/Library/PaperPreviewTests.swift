import Foundation
import PaperReaderKit
import Testing

@testable import PaperReaderUI

@MainActor struct PaperPreviewTests {
    @Test func pdfAbstractKeepsItsBoundariesAndPreviewFollowsLiveCloseReadingNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        let file = root.appendingPathComponent("test.pdf")
        try DemoPaper.write(to: file)
        let id = try #require(await reader.importURLs([file], selectAfterImport: false).first)
        let original = await reader.previewContent(for: id)
        #expect(original.abstract?.hasPrefix("Attention is a way") == true)
        #expect(original.abstract?.hasSuffix("interpreted carefully.") == true)
        #expect(!original.isChineseAbstract && original.oneSentence == nil)
        #expect(reader.selectedPaperID == nil && reader.state.chats.isEmpty)

        let paper = try #require(reader.state.papers.first)
        let version = paper.digest + ":original-0"
        var note = ReadingNote(
            paperID: id, contentVersion: version, anchors: [], markdown: "## 核心论点\n注意力权重取决于查询和键的匹配程度。")
        note.placement = .documentEnd
        var report = ChatTurn(paperID: id, question: "精读", selection: "", answer: "已检查原文。", evidence: [])
        report.closeReadingVersion = version
        report.readingNoteID = note.id
        reader.state.readingNotes = [note]
        reader.state.chats = [report]
        #expect(await reader.previewContent(for: id).oneSentence == "注意力权重取决于查询和键的匹配程度。")
        reader.state.readingNotes[0].markdown =
            "## 一句话概括\n**查询**决定检索时各个值的组合权重。\n\n[原文](paperreader://passage/fixture)\n\n## 实验\n还有其他内容。"
        #expect(await reader.previewContent(for: id).oneSentence == "查询决定检索时各个值的组合权重。")
        reader.state.readingNotes[0].deletedAt = .now
        #expect(await reader.previewContent(for: id).oneSentence == nil)
    }

    @Test func sourcePreviewUsesOnlyCompleteTranslatedAbstractAndSupportsInlineLabels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        let blocks = [
            "Abstract Interpretation of Scientific Papers",
            "Abstract We compare the predictions of two models under identical conditions.",
            "The second model makes fewer errors.", "1 Introduction", "A separate introduction.",
        ].map { TextBlock(sourcePage: 0, text: $0) }
        var paper = Paper(
            title: blocks[0].text, digest: "test", originalPath: "absent.pdf", pageCount: 0,
            blocks: blocks, warnings: [], canReflow: true)
        paper.translations = [blocks[1].id.uuidString: "摘要：我们在相同条件下比较了两种模型的预测。"]
        reader.state.papers = [paper]
        let partial = await reader.previewContent(for: paper.id)
        #expect(
            partial.abstract
                == "We compare the predictions of two models under identical conditions.\n\nThe second model makes fewer errors."
        )
        #expect(!partial.isChineseAbstract)
        reader.state.papers[0].translations[blocks[2].id.uuidString] = "第二种模型的错误更少。"
        let complete = await reader.previewContent(for: paper.id)
        #expect(complete.abstract == "我们在相同条件下比较了两种模型的预测。\n\n第二种模型的错误更少。")
        #expect(complete.isChineseAbstract)
        reader.state.papers[0].blocks = [blocks[0], blocks[3], blocks[4]]
        #expect(await reader.previewContent(for: paper.id).abstract == nil)
        var source = OnlinePaperSource(candidateID: "https://doi.org/10.1234/test")
        source.abstractText = "An indexed abstract with an explicit edition."
        reader.state.papers[0].onlineSource = source
        #expect(await reader.previewContent(for: paper.id).abstract == source.abstractText)
    }
}
