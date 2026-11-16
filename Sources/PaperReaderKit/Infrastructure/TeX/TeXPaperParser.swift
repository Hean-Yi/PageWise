import CryptoKit
import Foundation

public actor TeXPaperParser {
    public init() {}

    public func parse(_ archive: Data) async throws -> [TextBlock] {
        let files = try TeXArchive.unpack(archive)
        var document = try TeXDocument(files: files)
        let expanded = try document.expanded()
        let markup = try TeXMarkup().document(expanded)
        let transport = TeXAssetTransport(files: files)
        let source = URL(string: "https://arxiv.org/html/tex-local")!
        var blocks = try await HTMLPaperParser(transport: transport).parse(
            Data(markup.utf8), at: source, normalizeMath: false)
        guard !blocks.isEmpty, !blocks.contains(where: { $0.hasImageFailure == true }) else {
            throw TeXArchive.failure("正文或图件未完整转换")
        }
        let digest = Self.digest(archive)
        for index in blocks.indices {
            // IDs are deterministic for this exact archive and parser version, including restart before commit.
            let hash = Array(SHA256.hash(data: Data("tex-v1:\(digest):\(document.mainFile):\(index)".utf8)))
            blocks[index].id = UUID(
                uuid: (
                    hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                    hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
                ))
            blocks[index].texSource = TeXSourceAnchor(
                archiveDigest: digest, mainFile: document.mainFile, blockIndex: index)
            blocks[index].sourcePage = -1
        }
        return blocks
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The synthetic HTTPS address is only a namespace; no network client exists in this transport.
private struct TeXAssetTransport: HTTPTransport {
    let files: [String: Data]
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let prefix = "/html/tex-local/"
        guard let url = request.url, url.scheme == "https", url.host == "arxiv.org", url.path.hasPrefix(prefix),
            let data = files[String(url.path.dropFirst(prefix.count))],
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { throw TeXArchive.failure("包内图件不存在") }
        return (data, response)
    }
}
