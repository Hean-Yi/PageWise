import CryptoKit
import Foundation
import SwiftSoup
import Synchronization

/// Produces final reading files, not a cache. Callers publish references before removing old versions.
public actor HTMLReadingStore {
    private static let openDocuments = Mutex<[URL: Int]>([:])
    private static let publishingDirectories = Mutex<[URL: Int]>([:])
    let verifiedSections = HTMLVerifiedSections()
    public init() {}

    /// Includes the interval between staging bytes and committing the reference in the database.
    public static func withPublication<T: Sendable>(
        root: URL, paperID: UUID, isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let directory = readingDirectory(root: root, paperID: paperID)
        publishingDirectories.withLock { $0[directory, default: 0] += 1 }
        defer {
            publishingDirectories.withLock { counts in
                let remaining = (counts[directory] ?? 1) - 1
                counts[directory] = remaining == 0 ? nil : remaining
            }
        }
        return try await operation()
    }

    private static func readingDirectory(root: URL, paperID: UUID) -> URL {
        root.appendingPathComponent("Papers/\(paperID.uuidString)/reading", isDirectory: true).standardizedFileURL
    }

    /// The reader may close while another version is staged. Only the known retired file is eligible.
    public static func removeSupersededDocument(_ url: URL, root: URL, paper: Paper) {
        let file = url.standardizedFileURL
        guard file.deletingLastPathComponent().standardizedFileURL == readingDirectory(root: root, paperID: paper.id),
            file.lastPathComponent.range(of: #"^document-[0-9A-Fa-f-]{36}\.html$"#, options: .regularExpression) != nil,
            !([paper.htmlReading] + (paper.retainedReadings ?? []).map(\.html)).compactMap({ $0 }).contains(where: {
                root.appendingPathComponent($0.relativePath).standardizedFileURL == file
            })
        else { return }
        openDocuments.withLock { references in
            if references[file] == nil { try? FileManager.default.removeItem(at: file) }
        }
    }

    public static func retainOpenDocument(_ url: URL) {
        openDocuments.withLock { $0[url.standardizedFileURL, default: 0] += 1 }
    }

    public static func releaseOpenDocument(_ url: URL) {
        openDocuments.withLock { references in
            let key = url.standardizedFileURL
            let count = (references[key] ?? 1) - 1
            references[key] = count > 0 ? count : nil
        }
    }

    public func append(
        _ pairs: [BilingualBlock], to previous: HTMLReadingArtifact?, paper: Paper, root: URL
    ) throws
        -> HTMLReadingArtifact
    {
        let prefix = "Papers/\(paper.id.uuidString)/reading/"
        let folder = root.appendingPathComponent(prefix)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previousURL = previous.map { root.appendingPathComponent($0.relativePath) }
        var index: HTMLSectionIndex
        var header = ""
        if let previous, let previousURL {
            index =
                try previous.sectionIndex
                ?? HTMLSectionIndex.recover(
                    from: previousURL, paperID: paper.id, sections: previous.sections)
            let file = try FileHandle(forReadingFrom: previousURL)
            defer { try? file.close() }
            try index.validate(file: file, paperID: paper.id, count: previous.sections.count)
        } else {
            header = Self.header(title: paper.displayTitle, paperID: paper.id)
            index = .init(start: UInt64(header.utf8.count), ends: [])
        }
        let appendOffset = index.end
        var additions = Data()
        var sections = previous?.sections ?? []
        var outline = try previous.map { try navigationItems(for: $0, root: root) } ?? []
        var publishedIDs = Set(sections.flatMap(\.blockIDs))
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
        for pair in pairs {
            try Task.checkCancellation()
            guard publishedIDs.insert(pair.block.id).inserted else {
                throw ReaderError.message("内容块已发布，拒绝重复追加。")
            }
            var translationTag = "div"
            var html: String
            do {
                html = pair.block.richContent?.html ?? "<p>\(Self.escape(pair.block.text))</p>"
                let parsed = try SwiftSoup.parseBodyFragment(html)
                if pair.block.richContent == nil, let body = parsed.body() { try HTMLMathNormalizer.normalize(body) }
                if let body = parsed.body(),
                    let heading = try Self.outlineItem(
                        in: body, id: pair.block.id, page: pair.block.sourcePage,
                        hasSection: !outline.isEmpty)
                {
                    outline.append(heading)
                }
                if let tag = parsed.body()?.children().first(where: { $0.tagName() != "span" || !$0.hasAttr("id") })?
                    .tagName(),
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
            let section =
                "<section id='block-\(id.uuidString)' data-key='\(id.uuidString)' data-source='\(pair.block.sourcePage)'>\(html)</section>"
            additions.append(contentsOf: section.utf8)
            index.ends.append(appendOffset + UInt64(additions.count))
            sections.append(PageArtifact(id: id, blockIDs: [id], sourcePage: pair.block.sourcePage, relativePath: ""))
        }
        let path = prefix + "document-\(UUID().uuidString).html"
        let destination = root.appendingPathComponent(path)
        if let previousURL {
            try HTMLSectionIndex.append(additions, replacingTailAt: appendOffset, from: previousURL, to: destination)
        } else {
            var document = Data(header.utf8)
            document.append(additions)
            document.append(contentsOf: HTMLSectionIndex.closing.utf8)
            try document.write(to: destination, options: .withoutOverwriting)
        }
        created.append(destination)
        try Task.checkCancellation()
        for index in sections.indices { sections[index].relativePath = path }
        retained = true
        var artifact = HTMLReadingArtifact(relativePath: path, sections: sections, assets: assets.sorted())
        artifact.sectionIndex = index
        artifact.outline = outline
        artifact.editionID = previous?.editionID
        if previous?.sections.isEmpty != false, let first = sections.first?.id,
            ([paper.htmlReading] + (paper.retainedReadings ?? []).map(\.html)).contains(where: {
                $0?.sections.first?.id == first
            })
        {
            artifact.editionID = UUID()
        }
        return artifact
    }

    /// Startup recovery for files abandoned before a durable commit.
    public static func cleanup(root: URL, paper: Paper) throws {
        let directory = readingDirectory(root: root, paperID: paper.id)
        try publishingDirectories.withLock { publishing in
            guard publishing[directory] == nil else { return }
            try removeOrphans(in: directory, paper: paper)
        }
    }

    private static func removeOrphans(in directory: URL, paper: Paper) throws {
        let prefix = "Papers/\(paper.id.uuidString)/reading/"
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let retained = (paper.retainedReadings ?? []).compactMap(\.html)
        let kept = Set(
            (paper.htmlReading?.assets ?? []) + [paper.htmlReading?.relativePath ?? ""]
                + retained.flatMap { $0.assets + [$0.relativePath] })
        for url in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                !openDocuments.withLock({ $0[url.standardizedFileURL] != nil }),
                !kept.contains(prefix + url.lastPathComponent),
                url.lastPathComponent.range(
                    of: #"^(document-[0-9A-Fa-f-]{36}\.html|asset-[0-9a-f]{64}\.(png|svg))$"#,
                    options: .regularExpression) != nil
            else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    public func appendedContent(
        at url: URL, artifact: HTMLReadingArtifact, paperID: UUID, afterSectionCount: Int
    ) throws -> String {
        guard (0...artifact.sections.count).contains(afterSectionCount) else { throw HTMLSectionIndex.invalidDocument }
        let index =
            try artifact.sectionIndex
            ?? HTMLSectionIndex.recover(
                from: url, paperID: paperID, sections: artifact.sections)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try index.validate(file: file, paperID: paperID, count: artifact.sections.count)
        return try index.read(afterSectionCount..<artifact.sections.count, file: file)
    }

    private static func escape(_ text: String) -> String {
        HTMLPaperParser.escape(text).replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func header(title: String, paperID: UUID) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
        <title>\(HTMLPaperParser.escape(title))</title><style>
        .tex-bibliography{list-style:none;padding:0}.tex-bibliography li{padding-left:1.4em;text-indent:-1.4em;margin:.5em 0}
        :root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;background:#faf9f5;color:#252320;font:17px/1.8 -apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif;overflow-wrap:break-word}
        main{\(ReadingPageTypography.sourceColumn)}section{margin:0 0 24px}p,figure,pre,blockquote{margin:0 0 16px}
        h1,h2,h3,h4,h5,h6{font:650 1.25em/1.45 system-ui;margin:24px 0 12px}h1{font-size:1.8em;line-height:1.3;margin-top:0}h2{font-size:1.45em}.paper-authors{font:14px/1.7 system-ui;color:#706b62;margin:12px 0 28px}.paper-authors details{margin-top:8px}.paper-authors summary{cursor:pointer;color:#a34c33}.paper-authors details p{margin:8px 0}.paper-equation,.paper-equation td{border:0;padding:4px}.paper-equation{margin:24px auto;width:max-content;max-width:100%}#translation-draft{margin-top:24px}img{display:block;max-width:100%;max-height:min(45vh,320px);width:auto;height:auto;object-fit:contain;margin:auto;cursor:zoom-in}dialog{border:0;background:#faf9f5;padding:20px;max-width:96vw;max-height:96vh}dialog::backdrop{background:#0009}dialog img{max-width:90vw;max-height:82vh}dialog button{float:right;font:16px system-ui;border:0;background:transparent;cursor:pointer}a{color:#a34c33;text-decoration:underline;text-underline-offset:3px}table{display:block;overflow:auto;border-collapse:collapse;max-width:100%}td,th{padding:6px;border:1px solid #aaa}
        pre{overflow:auto;font:14px/1.6 monospace}math[display=block]{display:block;text-align:center;overflow-x:auto;max-width:100%;margin:24px 0}figcaption,.image-notice{font:14px/1.6 system-ui;color:#71572e}.translation{color:inherit;font-family:\(ReadingPageTypography.sourceChinese);margin-top:12px;border-top:1px solid #d9d4ca;border-left:1px solid #b9ac98;padding:12px 0 0 14px}h1.translation,h2.translation,h3.translation,h4.translation,h5.translation,h6.translation{font-family:system-ui;margin-bottom:28px}
        ::highlight(saved){background:#f2d36b;color:#292e2e}@media(prefers-color-scheme:dark){body{background:#24221f;color:#e4e1da}.translation{color:inherit}figcaption,.image-notice{color:#d0b784}}
        </style></head><body data-paper-id="\(paperID.uuidString)"><main id="reader">\(HTMLSectionIndex.opening)
        """
    }

}
