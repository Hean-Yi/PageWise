// Compile with scripts/check-reading-performance.sh. Uses only generated local content.
import AppKit
import Foundation
import PDFKit
import WebKit

@testable import PaperReaderKit
@testable import PaperReaderUI

@main struct ReadingPerformance {
    @MainActor static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Performance probe failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        print("low_power_mode", ProcessInfo.processInfo.isLowPowerModeEnabled)
        let prewarmed = CommandLine.arguments.contains("--prewarm")
        if prewarmed {
            HTMLWebViewPool.prewarm()
            try await Task.sleep(for: .seconds(2))
        }
        let root = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".local/reading-performance", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = try ReaderModel(root: root)
        await model.load()
        let blocks = (0..<100).map { index in
            TextBlock(
                sourcePage: index,
                text: "Section \(index + 1). "
                    + String(
                        repeating:
                            "Stable evidence remains selectable while the reader scrolls continuously through locally stored content. ",
                        count: 8))
        }
        var paper = Paper(
            title: "Continuous reading benchmark", digest: "local-performance", originalPath: "unused.pdf",
            pageCount: 100, blocks: blocks, warnings: [], canReflow: true)
        let started = DispatchTime.now().uptimeNanoseconds
        paper.htmlReading = try await HTMLReadingStore().append(
            blocks.map { BilingualBlock(block: $0, translation: "本地原创性能样例，用于测试连续阅读、文本选择和稳定定位。") }, to: nil,
            paper: paper, root: root)
        paper.translatedBlockCount = blocks.count
        print("build_html_100_sections_ms", elapsed(started))
        let artifact = paper.htmlReading!
        print("html_bytes", try Data(contentsOf: root.appendingPathComponent(artifact.relativePath)).count)
        model.state.papers = [paper]
        model.select(paper.id)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 850, height: 700), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "PaperReader — local performance fixture"
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        var samples: [Double] = []
        for run in 0..<8 {
            let start = DispatchTime.now().uptimeNanoseconds
            let coordinator = HTMLCoordinator(model: model)
            let view = coordinator.makeView()
            window.contentView = view
            coordinator.update(view)
            var ready = false
            for _ in 0..<5_000 {
                let value = try? await view.callAsyncJavaScript(
                    "return !!window.paperReader && document.querySelectorAll('#reader > section').length === 100",
                    arguments: [:], in: nil, contentWorld: .defaultClient)
                if value as? Bool == true {
                    ready = true
                    break
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard ready else {
                print(
                    "timeout", run, "url", view.url?.absoluteString ?? "nil", "mode", model.mode, "error",
                    model.message ?? "nil")
                do {
                    print(
                        "DOM",
                        try await view.callAsyncJavaScript(
                            "return {text:document.body.innerText.slice(0,100),count:document.querySelectorAll(\"section\").length,bridge:!!window.paperReader}",
                            arguments: [:], in: nil, contentWorld: .defaultClient) as Any)
                } catch { print("JS error", error) }
                coordinator.stop(view)
                throw ReaderError.message("Reader timed out")
            }
            _ = try await view.callAsyncJavaScript(
                "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
                arguments: [:], in: nil, contentWorld: .defaultClient)
            samples.append(elapsed(start))
            if run == 7 {
                let intervals =
                    try await view.callAsyncJavaScript(
                        "const values=[]; for(let i=0;i<120;i++){ const start=performance.now(); scrollBy(0,80); await new Promise(requestAnimationFrame); values.push(performance.now()-start); } return values",
                        arguments: [:], in: nil, contentWorld: .defaultClient) as? [Double] ?? []
                report("scroll_120_frame_intervals", intervals)
                _ = try await view.callAsyncJavaScript(
                    "scrollTo(0,0); await new Promise(requestAnimationFrame)", arguments: [:], in: nil,
                    contentWorld: .defaultClient)
                let image = try await view.takeSnapshot(configuration: nil)
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    try png.write(to: root.appendingPathComponent("preview.png"))
                }
            }
            coordinator.stop(view)
            window.contentView = nil
            // Give the empty engine a chance to finish clearing the previous document.
            try await Task.sleep(for: .milliseconds(50))
        }
        print(prewarmed ? "empty_engine_prewarmed_open_two_frames_ms" : "cold_engine_open_two_frames_ms", samples[0])
        report("warm_engine_open_two_frames", Array(samples.dropFirst()))
        model.select(nil)
        window.orderOut(nil)
        await model.flushReadingPosition()
        try await benchmarkImport(root: root)
    }

    @MainActor static func benchmarkImport(root: URL) async throws {
        let folder = root.appendingPathComponent("import-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let demo = folder.appendingPathComponent("demo.pdf")
        try DemoPaper.write(to: demo)
        guard let source = PDFDocument(url: demo) else { throw ReaderError.message("Fixture missing") }
        let combined = PDFDocument()
        for _ in 0..<50 {
            for index in 0..<source.pageCount {
                guard let copy = source.page(at: index)?.copy() as? PDFPage else {
                    throw ReaderError.message("Fixture page missing")
                }
                combined.insert(copy, at: combined.pageCount)
            }
        }
        let input = folder.appendingPathComponent("input.pdf")
        guard combined.write(to: input), let document = PDFDocument(url: input) else {
            throw ReaderError.message("Fixture write failed")
        }
        let blocks = (0..<document.pageCount).map { index in
            let text = document.page(at: index)?.string ?? ""
            var block = TextBlock(sourcePage: index, text: text)
            block.richContent = RichContent(
                html: "<p>" + HTMLPaperParser.escape(text) + "</p>", translationInput: text, mathematics: [:],
                mathDescriptions: [:])
            return block
        }
        for structured in [false, true] {
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                let paper = try await PDFImporter(root: folder).importPDF(
                    at: input, preservingComplexPages: true, structuredBlocks: structured ? blocks : nil)
                samples.append(elapsed(start))
                try FileManager.default.removeItem(
                    at: folder.appendingPathComponent(paper.originalPath).deletingLastPathComponent())
            }
            report(structured ? "structured_import_100_pages" : "pdf_import_100_pages", samples)
        }
    }

    static func elapsed(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    static func report(_ name: String, _ values: [Double]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        print(
            name, "p50_ms", sorted[sorted.count / 2], "p95_ms",
            sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)], "max_ms", sorted.last!)
    }
}
