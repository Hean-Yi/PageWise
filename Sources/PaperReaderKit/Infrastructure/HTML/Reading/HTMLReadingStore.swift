import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import SwiftSoup
import UniformTypeIdentifiers

/// Produces final reading files, not a cache. Callers publish references before removing old versions.
public actor HTMLReadingStore {
    public init() {}

    public func append(_ pairs: [BilingualBlock], to previous: HTMLReadingArtifact?, paper: Paper, root: URL) throws
        -> HTMLReadingArtifact
    {
        let prefix = "Papers/\(paper.id.uuidString)/reading/"
        let folder = root.appendingPathComponent(prefix)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var content = ""
        if let previous {
            let old = try String(contentsOf: root.appendingPathComponent(previous.relativePath), encoding: .utf8)
            guard let start = old.range(of: Self.start), let end = old.range(of: Self.end, options: .backwards),
                start.upperBound <= end.lowerBound
            else { throw ReaderError.message("已保存的阅读内容无法完整读取，未覆盖。") }
            content = String(old[start.upperBound..<end.lowerBound])
        }
        var sections = previous?.sections ?? []
        var assets = Set(previous?.assets ?? [])
        var created: [URL] = []
        var retained = false
        defer { if !retained { for url in created { try? FileManager.default.removeItem(at: url) } } }
        func saveAsset(_ bytes: Data, ext: String) throws -> String {
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let name = "asset-\(hash).\(ext)"
            let file = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) {
                try bytes.write(to: file, options: .withoutOverwriting)
                created.append(file)
            }
            assets.insert(prefix + name)
            return name
        }
        var sourcePDF: PDFDocument?
        for pair in pairs {
            try Task.checkCancellation()
            guard !sections.contains(where: { $0.blockIDs.contains(pair.block.id) }) else {
                throw ReaderError.message("内容块已发布，拒绝重复追加。")
            }
            var html: String
            var translationTag = "div"
            if pair.block.preservesSourcePage == true {
                if sourcePDF == nil { sourcePDF = PDFDocument(url: root.appendingPathComponent(paper.originalPath)) }
                guard let sourcePDF, (0..<sourcePDF.pageCount).contains(pair.block.sourcePage),
                    let page = sourcePDF.page(at: pair.block.sourcePage)
                else { throw ReaderError.message("原始页无法读取，未发布缺失内容。") }
                let (bytes, width, height) = try Self.raster(page)
                let name = try saveAsset(bytes, ext: "png")
                html =
                    "<figure><img src='\(name)' width='\(width)' height='\(height)' loading='lazy' alt='保留的原始页面'><figcaption>此页保留原版图表与公式；可切换原版查看和批注。</figcaption></figure>"
            } else {
                html = pair.block.richContent?.html ?? "<p>\(Self.escape(pair.block.text))</p>"
                let parsed = try SwiftSoup.parseBodyFragment(html)
                if pair.block.richContent == nil, let body = parsed.body() { try HTMLMathNormalizer.normalize(body) }
                if let tag = parsed.body()?.children().first()?.tagName(),
                    ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag)
                {
                    translationTag = tag
                }
                for image in try parsed.select("img") {
                    let uri = try image.attr("src")
                    guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
                        let bytes = Data(base64Encoded: String(uri[uri.index(after: comma)...])),
                        uri.hasPrefix("data:image/png;") || uri.hasPrefix("data:image/svg+xml;")
                    else { throw ReaderError.message("图片资源不完整，未发布重排内容。") }
                    let name = try saveAsset(bytes, ext: uri.hasPrefix("data:image/svg+xml;") ? "svg" : "png")
                    try image.attr("src", name).attr("loading", "lazy").attr("decoding", "async")
                }
                html = try parsed.body()?.html() ?? ""
            }
            if let translation = pair.translation {
                try pair.block.richContent?.validate(translation)
                var translated = Self.escape(translation)
                for (marker, math) in pair.block.richContent?.mathematics ?? [:] {
                    translated = translated.replacingOccurrences(of: marker, with: math)
                }
                let translatedDocument = try SwiftSoup.parseBodyFragment(translated)
                if let body = translatedDocument.body() { try HTMLMathNormalizer.normalize(body) }
                translated = try translatedDocument.body()?.html() ?? translated
                html += "<\(translationTag) class='translation' lang='zh-Hans'>\(translated)</\(translationTag)>"
            }
            let id = pair.block.id
            content +=
                "<section id='block-\(id.uuidString)' data-key='\(id.uuidString)' data-source='\(pair.block.sourcePage)'>\(html)</section>"
            sections.append(PageArtifact(id: id, blockIDs: [id], sourcePage: pair.block.sourcePage, relativePath: ""))
        }
        let path = prefix + "document-\(UUID().uuidString).html"
        let destination = root.appendingPathComponent(path)
        try Data(Self.document(content: content, title: paper.title, paperID: paper.id).utf8).write(
            to: destination, options: .withoutOverwriting)
        created.append(destination)
        try Task.checkCancellation()
        for index in sections.indices { sections[index].relativePath = path }
        retained = true
        return HTMLReadingArtifact(relativePath: path, sections: sections, assets: assets.sorted())
    }

    /// Removes only application-owned unreferenced files. Safe at startup or after a commit.
    public static func cleanup(root: URL, paper: Paper) throws {
        let prefix = "Papers/\(paper.id.uuidString)/reading/"
        let directory = root.appendingPathComponent(prefix)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let kept = Set((paper.htmlReading?.assets ?? []) + [paper.htmlReading?.relativePath ?? ""])
        for url in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                !kept.contains(prefix + url.lastPathComponent),
                url.lastPathComponent.range(
                    of: #"^(document-[0-9A-Fa-f-]{36}\.html|asset-[0-9a-f]{64}\.(png|svg))$"#,
                    options: .regularExpression) != nil
            else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    public func appendedContent(at url: URL, excluding keys: Set<String>) throws -> String {
        let document = try SwiftSoup.parse(String(contentsOf: url, encoding: .utf8))
        return try document.select("#reader > section").filter { !keys.contains(try $0.attr("data-key")) }
            .map { try $0.outerHtml() }.joined()
    }

    private static let start = "<!--paperreader-content-start-->"
    private static let end = "<!--paperreader-content-end-->"
    private static func escape(_ text: String) -> String {
        HTMLPaperParser.escape(text).replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func document(content: String, title: String, paperID: UUID) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
        <title>\(HTMLPaperParser.escape(title))</title><style>
        :root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;background:#fff;color:#202020;font:18px/1.75 -apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif;overflow-wrap:break-word}
        main{max-width:960px;margin:auto;padding:28px clamp(20px,5vw,56px) 80px}section{margin:0 0 24px}p,figure,pre,blockquote{margin:0 0 16px}
        h1,h2,h3,h4,h5,h6{font:700 1.5em/1.4 system-ui;margin:0 0 14px}img{display:block;max-width:100%;height:auto;margin:auto}table{display:block;overflow:auto;border-collapse:collapse;max-width:100%}td,th{padding:6px;border:1px solid #aaa}
        pre{overflow:auto;font:14px/1.6 monospace}math[display=block]{display:block;text-align:center;overflow-x:auto;max-width:100%;margin:24px 0}figcaption,.image-notice{font:14px/1.6 system-ui;color:#71572e}.translation{color:inherit;font-family:'Songti SC','STSong',serif;margin-top:12px}h1.translation,h2.translation,h3.translation,h4.translation,h5.translation,h6.translation{font-family:system-ui;margin-bottom:28px}
        ::highlight(saved){background:#f2d36b;color:#292e2e}@media(prefers-color-scheme:dark){body{background:#232626;color:#e4e7e5}.translation{color:inherit}figcaption,.image-notice{color:#d0b784}}
        </style></head><body data-paper-id="\(paperID.uuidString)"><main id="reader">\(start)\(content)\(end)</main></body></html>
        """
    }

    private static func raster(_ page: PDFPage) throws -> (Data, Int, Int) {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw ReaderError.message("原始页面尺寸无效，未生成不完整图片。")
        }
        let rotated = abs(page.rotation % 180) == 90
        let logicalWidth = rotated ? bounds.height : bounds.width
        let logicalHeight = rotated ? bounds.width : bounds.height
        let scale = min(2, 2_400 / max(logicalWidth, logicalHeight))
        // PDFKit's thumbnail path accounts for crop origin, rotation and visible annotations.
        let thumbnail = page.thumbnail(
            of: CGSize(width: logicalWidth * scale, height: logicalHeight * scale), for: .cropBox)
        #if os(macOS)
            let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
            let image = thumbnail.cgImage
        #endif
        guard let image else { throw ReaderError.message("原始页图片生成失败。") }
        let width = image.width
        let height = image.height
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else {
            throw ReaderError.message("原始页图片编码失败。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ReaderError.message("原始页图片编码失败。") }
        return (data as Data, width, height)
    }
}
