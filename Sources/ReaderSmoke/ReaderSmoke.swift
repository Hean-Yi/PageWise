import Foundation
import PDFKit
import PaperReaderKit

#if os(macOS)
    import AppKit
#endif

@main
struct ReaderSmoke {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--audit-pdf-evidence" {
            try await PDFReflowAudit.run(
                root: URL(fileURLWithPath: CommandLine.arguments[2]),
                report: URL(fileURLWithPath: CommandLine.arguments[3]), modelEvidence: true)
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--audit-library" {
            try await PDFReflowAudit.run(
                root: URL(fileURLWithPath: CommandLine.arguments[2]),
                report: URL(fileURLWithPath: CommandLine.arguments[3]))
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--audit-published-library" {
            try await PublishedReflowAudit.run(
                root: URL(fileURLWithPath: CommandLine.arguments[2]),
                report: URL(fileURLWithPath: CommandLine.arguments[3]))
            return
        }
        let argument = CommandLine.arguments.dropFirst().first ?? ".local/smoke"
        let root = URL(fileURLWithPath: argument, isDirectory: true).appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Demo.pdf")
        try DemoPaper.write(to: source)
        let imported = try await PDFImporter(root: root).importPDF(at: source)
        guard imported.canReflow, !imported.blocks.isEmpty else {
            throw ReaderError.message("示例 PDF 未通过重排检查：\(imported.warnings)")
        }
        let renderer = PageRenderer()
        let pageDir = root.appendingPathComponent("Preview")
        let pairs = imported.blocks.prefix(3).map {
            BilingualBlock(
                block: $0,
                translation: "这是用于检查双语排版的本地示例译文，并非 GLM 的实际结果。注意力根据查询与键的相似程度选择相关信息，然后对值进行加权。原文段落和来源保持对应，手写批注绑定固定页面。")
        }
        let first = try renderer.render(Array(pairs), to: pageDir, prefix: "sample")
        guard let page = first.first else { throw ReaderError.message("未生成页面") }
        let pageURL = pageDir.appendingPathComponent(page.relativePath)
        let before = try Data(contentsOf: pageURL)
        _ = try renderer.render(Array(pairs), to: pageDir, prefix: "sample")
        guard try Data(contentsOf: pageURL) == before else { throw ReaderError.message("旧页面发生变化") }
        let store = try LibraryStore(directory: root)
        var state = LibraryState()
        state.papers = [imported]
        try await store.save(state)
        let loaded = try await LibraryStore(directory: root).load()
        guard loaded.papers[0].id == imported.id else { throw ReaderError.message("书库重启验证失败") }
        let note = try NoteMerger.merge(
            existing: "# 用户笔记\n\n自己的观点应保留。\n", body: "## 示例总结\n\n这是测试内容。", paperID: imported.id, baseline: nil)
        try Data(note.text.utf8).write(to: root.appendingPathComponent("Note.md"), options: .atomic)
        #if os(macOS)
            if let pdf = PDFDocument(url: pageURL), let firstPage = pdf.page(at: 0) {
                let image = firstPage.thumbnail(of: NSSize(width: 918, height: 1188), for: .mediaBox)
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    try png.write(to: root.appendingPathComponent("page-preview.png"))
                }
            }
        #endif
        try await StructuredSmoke.run(in: root)
        try await FigureCropSmoke.run(in: root)
        print(
            "PASS: local PDF import, \(imported.blocks.count) blocks, \(first.count) bilingual pages, immutable append, library restart, note generation"
        )
        print("Artifacts: \(root.path)")
    }
}
