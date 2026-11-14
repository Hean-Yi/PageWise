import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import PaperReaderKit

#if os(macOS)
    import AppKit
#endif

private struct SmokeImageTransport: HTTPTransport {
    let bytes: Data
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.path == "/html/2401.00001v1/figure.png" else {
            throw ReaderError.message("Unexpected fixture resource")
        }
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor enum StructuredSmoke {
    static func run(in root: URL) async throws {
        #if os(macOS)
            _ = NSApplication.shared
        #endif
        let context = CGContext(
            data: nil, width: 640, height: 220, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 220))
        for (index, height) in [70, 130, 175, 100].enumerated() {
            context.setFillColor(CGColor(red: 0.2, green: 0.4 + Double(index) * 0.08, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 50 + index * 145, y: 20, width: 90, height: height))
        }
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw ReaderError.message("Fixture PNG failed") }
        let html = """
            <article class="ltx_document">
              <h1>Evidence, queries and fixed pages</h1>
              <p>This original teaching example checks selectable text, mathematical structure and stable bilingual pagination.</p>
              <p>A query <math alttext="q_i"><msub><mi>q</mi><mi>i</mi></msub></math> selects evidence using
              <math alttext="s = qk / sqrt(d)"><mi>s</mi><mo>=</mo><mfrac><mrow><mi>q</mi><mi>k</mi></mrow><msqrt><mi>d</mi></msqrt></mfrac></math>.</p>
              <figure><img src="2401.00001v1/figure.png"><figcaption>Figure 1. An original fixture chart; values are illustrative.</figcaption></figure>
              <table><thead><tr><th>Source</th><th>Result</th></tr></thead><tbody><tr><td>Text and MathML</td><td>Selectable fixed pages</td></tr><tr><td>Complex PDF page</td><td>Original geometry retained</td></tr></tbody></table>
              <figure><svg xmlns="http://www.w3.org/2000/svg" width="1200" height="320" viewBox="0 0 1200 320">
                <defs><linearGradient id="color"><stop offset="0" stop-color="#376d74"/><stop offset="1" stop-color="#a5d5b5"/></linearGradient>
                <clipPath id="boundary"><rect width="1200" height="320" rx="20"/></clipPath></defs>
                <g clip-path="url(#boundary)"><rect width="1200" height="320" fill="url(#color)"/>
                <path d="M60 250 L300 160 L540 200 L780 65 L1140 115" fill="none" stroke="#143947" stroke-width="6"/>
                <text x="60" y="70" font-size="30" fill="white">SVG: paths, gradients, clipping and text</text></g>
              </svg><figcaption>Figure 2. A wide vector figure retains its complete curve and labels.</figcaption></figure>
              <figure><svg xmlns="http://www.w3.org/2000/svg" width="440" height="1400" viewBox="0 0 440 1400">
                <rect x="20" y="20" width="400" height="1360" rx="20" fill="#e4eee7" stroke="#376d74" stroke-width="3"/>
                <path d="M220 200 L220 1200" stroke="#376d74" stroke-width="5"/>
                <circle cx="220" cy="200" r="70" fill="#90bdb0"/><circle cx="220" cy="700" r="70" fill="#90bdb0"/>
                <circle cx="220" cy="1200" r="70" fill="#90bdb0"/>
                <text x="185" y="210" font-size="24">Input</text><text x="175" y="710" font-size="24">Model</text>
                <text x="180" y="1210" font-size="24">Result</text>
              </svg><figcaption>Figure 3. A tall vector diagram keeps the final node and caption visible.</figcaption></figure>
            </article>
            """
        let blocks = try await HTMLPaperParser(transport: SmokeImageTransport(bytes: png as Data)).parse(
            Data(html.utf8), at: URL(string: "https://arxiv.org/html/2401.00001v1")!)
        let translations = [
            "证据、查询与固定页面", "这是原创教学样例，用于检查可选择文字、数学结构和稳定的双语分页。以下译文为本地测试内容。", "查询 [[MATH_1]] 使用 [[MATH_2]] 选择证据。",
            "图 1：原创测试图表，数值仅作示意。", "文字与数学结构生成可选文字的固定页；复杂 PDF 页面保留原有几何。",
            "图 2：宽幅矢量图完整保留曲线、渐变、裁剪与文字，放大后仍清晰。", "图 3：长图完整保留末尾节点和图注，不裁切、不变形。",
        ]
        let pairs = zip(blocks, translations).map { BilingualBlock(block: $0.0, translation: $0.1) }
        let directory = root.appendingPathComponent("Structured")
        let pages = try await StructuredPageRenderer().render(
            pairs, to: directory, originalURL: root.appendingPathComponent("Demo.pdf"))
        _ = try PDFDisplayDocument.load(
            urls: pages.map { directory.appendingPathComponent($0.relativePath) }, expectedPageCount: pages.count)
        for (index, page) in pages.enumerated() {
            #if os(macOS)
                let document = PDFDocument(url: directory.appendingPathComponent(page.relativePath))!
                let image = document.page(at: 0)!.thumbnail(of: NSSize(width: 918, height: 1188), for: .mediaBox)
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try bitmap.representation(using: .png, properties: [:])!.write(
                    to: root.appendingPathComponent("structured-\(index + 1).png"))
            #endif
        }
        print("PASS: structured HTML, inline MathML, embedded original figure, table, \(pages.count) fixed pages")
    }
}
