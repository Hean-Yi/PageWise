import Foundation
import PaperReaderKit
import PaperReaderTestSupport
import Testing

@testable import PaperReaderUI

@MainActor struct PaperPreviewTests {
    @Test func pdfAbstractKeepsItsBoundariesAndPreviewFollowsLiveCloseReadingNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        let file = root.appendingPathComponent("test.pdf")
        try AttentionFixture.write(to: file)
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
        reader.state.readingNotes[0].markdown = "## 核心论点\n这是全文的核心设计问题。查询与键的内积决定权重。"
        #expect(await reader.previewContent(for: id).oneSentence == "查询与键的内积决定权重。")
        reader.state.readingNotes[0].markdown = "## 一句话概括\n这是全文的核心设计问题。"
        #expect(await reader.previewContent(for: id).oneSentence == nil)
        reader.state.readingNotes[0].markdown = "## 一句话概括\n作者在此处阐述了本文的关键贡献。匹配预算后原有排序反转。"
        #expect(await reader.previewContent(for: id).oneSentence == "匹配预算后原有排序反转。")
        reader.state.readingNotes[0].deletedAt = .now
        #expect(await reader.previewContent(for: id).oneSentence == nil)
    }

    @Test func existingLibraryBackfillsBeforeAnyPreviewAndReusesTheAbstractAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: root)
        let input = root.appendingPathComponent("old-paper.pdf")
        try AttentionFixture.write(to: input)
        let paper = try await PDFImporter(root: root).storeOriginal(at: input)
        var library = LibraryState()
        library.papers = [paper]
        try await store.save(library)

        let first = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await first.load()
        await first.abstractBackfill?.value
        try FileManager.default.removeItem(at: root.appendingPathComponent(paper.originalPath))

        let reopened = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reopened.load()
        let preview = await reopened.previewContent(for: paper.id)
        #expect(preview.abstract?.hasPrefix("Attention is a way") == true)
        #expect(preview.abstract?.hasSuffix("interpreted carefully.") == true)
        await reopened.abstractBackfill?.value
    }

    @Test func unlabelledSourceBlocksUseCompleteExistingTranslationsOfTheRegisteredAbstract() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ReaderModel(root: root, credentials: WorkflowCredentials())
        await reader.load()
        let blocks = [
            "Estimating errors", "We study errors in long-term forecasts.",
            "The late forecast reduces variance.", "1 Introduction",
        ].map { TextBlock(sourcePage: 0, text: $0) }
        var paper = Paper(
            title: blocks[0].text, digest: "unlabelled", originalPath: "absent.pdf", pageCount: 1,
            blocks: blocks, warnings: [], canReflow: true)
        var source = OnlinePaperSource(candidateID: "https://doi.org/10.1234/test")
        source.abstractText = "We study errors in long-\nterm forecasts. The late forecast reduces variance."
        paper.onlineSource = source
        paper.translations = [blocks[1].id.uuidString: "我们分析长期预测中的误差。"]
        reader.state.papers = [paper]
        let original = await reader.previewContent(for: paper.id)
        #expect(original.isChineseAbstract == false && original.abstract?.contains(blocks[2].text) == true)
        reader.state.papers[0].translations[blocks[2].id.uuidString] = "较晚的预测降低了方差。"
        let chinese = await reader.previewContent(for: paper.id)
        #expect(chinese.abstract == "我们分析长期预测中的误差。\n\n较晚的预测降低了方差。")
        // A changed published claim cannot inherit this block's translation.
        reader.state.papers[0].onlineSource?.abstractText =
            "We study errors in long-term forecasts. The late forecast reduces variance by 1.5%."
        #expect(await reader.previewContent(for: paper.id).isChineseAbstract == false)
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
