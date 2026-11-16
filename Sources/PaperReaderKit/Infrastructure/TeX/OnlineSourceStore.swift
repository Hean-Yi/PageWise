import Foundation

public actor OnlineSourceStore {
    public init() {}

    /// Called inside the import's staging lifetime. The caller owns rollback until the database commits.
    public func attach(_ download: DownloadedPublication, to paper: Paper, root: URL) throws -> Paper {
        guard ArxivClient.verified(download.candidate) != nil else { throw ReaderError.message("论文来源无效。") }
        var paper = paper
        var source = OnlinePaperSource(candidateID: download.candidate.id, notice: download.sourceNotice)
        if let archive = download.texArchive {
            guard ArxivClient.versionedIdentifier(download.candidate.id) != nil,
                archive.count <= 50_000_000, TeXArchive.looksLikeSource(archive)
            else { throw ReaderError.message("源码包版本或格式无效。") }
            let digest = TeXPaperParser.digest(archive)
            let relative = "Papers/\(paper.id.uuidString)/source-\(digest).archive"
            let target = root.appendingPathComponent(relative)
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: target.path) {
                guard try TeXPaperParser.digest(Data(contentsOf: target)) == digest else {
                    throw TeXArchive.failure("已有源码文件未通过校验")
                }
            } else {
                let staging = target.deletingLastPathComponent().appendingPathComponent(".source-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: staging) }
                try archive.write(to: staging, options: .withoutOverwriting)
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: staging, to: target)
            }
            source.archivePath = relative
            source.archiveDigest = digest
        }
        paper.onlineSource = source
        paper.canReflow = true
        if let notice = source.notice { paper.warnings.append(notice) }
        return paper
    }

    public func prepare(paper: Paper, root: URL, discovery: any PaperDiscovery = ArxivClient()) async throws
        -> OnlineReflowEvidence
    {
        guard let source = paper.onlineSource,
            let identifier = ArxivClient.versionedIdentifier(source.candidateID)
        else { throw ReaderError.message("此论文没有可用的线上源码，请阅读原版 PDF。") }
        let original = try Data(contentsOf: root.appendingPathComponent(paper.originalPath))
        guard TeXPaperParser.digest(original) == paper.digest else {
            throw ReaderError.message("原始 PDF 内容已变化，未发布新版本。")
        }
        var warnings: [String] = []
        if let path = source.archivePath {
            do {
                guard let digest = source.archiveDigest,
                    path == "Papers/\(paper.id.uuidString)/source-\(digest).archive",
                    digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
                else {
                    throw TeXArchive.failure("保存路径无效")
                }
                let data = try Data(contentsOf: root.appendingPathComponent(path))
                guard TeXPaperParser.digest(data) == source.archiveDigest else {
                    throw TeXArchive.failure("已保存源码内容发生变化")
                }
                let blocks = try await TeXPaperParser().parse(data)
                return OnlineReflowEvidence(blocks: blocks, route: "tex", warnings: [])
            } catch is CancellationError { throw CancellationError() } catch {
                try Task.checkCancellation()
                warnings.append("TeX 解析未完整通过，改用同版本其他来源。" + error.localizedDescription)
            }
        }
        let candidate = PaperCandidate(
            id: source.candidateID, title: paper.title, authors: "", year: "",
            pdfURL: URL(string: "https://arxiv.org/pdf/" + identifier)!)
        do {
            if let blocks = try await discovery.structuredContent(candidate), !blocks.isEmpty,
                !blocks.contains(where: { $0.hasImageFailure == true })
            {
                warnings.append("本次重排使用同版本 HTML。")
                return OnlineReflowEvidence(blocks: blocks, route: "html", warnings: warnings)
            }
        } catch is CancellationError { throw CancellationError() } catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
        }
        throw ReaderError.message((warnings + ["未能取得完整的 TeX 或同版本 HTML，请阅读原版 PDF。"]).joined(separator: "\n"))
    }
}

public struct OnlineReflowEvidence: Sendable {
    public var blocks: [TextBlock]
    public var route: String
    public var warnings: [String]
}
