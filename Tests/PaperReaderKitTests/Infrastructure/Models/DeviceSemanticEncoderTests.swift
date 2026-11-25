import Foundation
import Testing

@testable import PaperReaderKit

@Test func missingE5AssetsNeverDownloadOnSearchAndRejectCorruptWeights() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let encoder = DeviceSemanticEncoder(directory: root)
    #expect(await !encoder.isInstalled())
    await #expect(throws: (any Error).self) { try await encoder.encode(["hello"], as: .query) }
    let bytes = root.appendingPathComponent("asset")
    try Data("test".utf8).write(to: bytes)
    let asset = E5ModelResources.Asset(
        source: "", path: "asset", bytes: 4,
        digest: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
    try E5ModelResources.verify(bytes, asset: asset)
    try Data("fail".utf8).write(to: bytes)
    #expect(throws: (any Error).self) { try E5ModelResources.verify(bytes, asset: asset) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["asset"])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PAGEWISE_SEMANTIC_TEST_ASSETS"] != nil))
func pinnedE5ModelEncodesAndInstallsOffline() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["PAGEWISE_SEMANTIC_TEST_ASSETS"])
    let files = FileManager.default
    let parent = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: parent) }
    let encoder = DeviceSemanticEncoder(
        directory: parent, transport: OfflineAssets(directory: URL(fileURLWithPath: path)))
    try await encoder.install()
    #expect(await encoder.isInstalled())
    let passage = try await encoder.encode(
        [
            "The authors matched the training compute across all experimental conditions.",
            "The garden will need more water during the hot summer months.",
        ], as: .passage)
    let query = try #require(try await encoder.encode(["计算预算匹配的条件下，实验有多可靠？"], as: .query).first)
    #expect(query.count == 384 && passage.count == 2)
    let scores = passage.map { zip($0, query).map(*).reduce(0, +) }
    // Official intfloat ONNX O4 with its HF tokenizer and masked mean pooling on the unpadded inputs.
    #expect(abs(scores[0] - 0.758378) < 0.003)
    #expect(abs(scores[1] - 0.708252) < 0.003)
    #expect(abs(query.map { $0 * $0 }.reduce(0, +) - 1) < 0.001)
    try await encoder.uninstall()
    #expect(await !encoder.isInstalled())
}

private struct OfflineAssets: HTTPTransport {
    let directory: URL
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func downloadFile(for request: URLRequest, maximumBytes: Int64) async throws -> (URL, HTTPURLResponse) {
        let url = try #require(request.url)
        let asset = try #require(E5ModelResources.assets.first { $0.source + $0.path == url.absoluteString })
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: directory.appendingPathComponent(asset.path), to: copy)
        return (copy, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
