import CoreML
import CryptoKit
import Foundation

/// Fixed upstream revisions. Only the verified data and model specification enter Core ML.
enum E5ModelResources {
    static let package = "MultilingualE5Small.mlpackage"
    static let model = "MultilingualE5Small.mlmodelc"
    static let tokenizer = "sentencepiece.bpe.model"
    static let revision = "e5-4c124bb3-spm1"
    private static let converted =
        "https://huggingface.co/tamikisg/multilingual-e5-small-coreml/resolve/4c124bb3c5fa88dba23279263df88e3d98fe0c51/"
    private static let upstream =
        "https://huggingface.co/intfloat/multilingual-e5-small/resolve/614241f622f53c4eeff9890bdc4f31cfecc418b3/"

    struct Asset {
        let source: String
        let path: String
        let bytes: Int
        let digest: String
    }

    static let assets = [
        Asset(
            source: upstream, path: tokenizer, bytes: 5_069_051,
            digest: "cfc8146abe2a0488e9e2a0c56de7952f7c11ab059eca145a0a727afce0db2865"),
        Asset(
            source: converted, path: package + "/Manifest.json", bytes: 617,
            digest: "af2f01cb5f0cbf22832c9cec2881ea730df4eb65ecd20334245cf823edca11b9"),
        Asset(
            source: converted, path: package + "/Data/com.apple.CoreML/model.mlmodel", bytes: 142_664,
            digest: "00155ee760470932d9838bc6fefc817a48c78a15692e73aa799dd3bd853b0fbb"),
        Asset(
            source: converted, path: package + "/Data/com.apple.CoreML/weights/weight.bin", bytes: 235_022_976,
            digest: "a19a797849ea945825c679fb6ed3b7bbf9c046a0aee1a90c12b72d76bd13b6e5"),
    ]

    static func verify(_ file: URL, asset: Asset) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == asset.bytes else { throw ReaderError.message("模型文件大小不符，请重新下载。") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.digest else {
            throw ReaderError.message("模型校验失败，请重新下载。")
        }
    }

    static func download(_ asset: Asset, transport: any HTTPTransport) async throws -> URL {
        var url = URL(string: asset.source + asset.path)!
        for _ in 0..<6 {
            try Task.checkCancellation()
            let (file, response) = try await transport.downloadFile(
                for: URLRequest(url: url), maximumBytes: Int64(asset.bytes))
            if response.statusCode == 200 {
                do {
                    try verify(file, asset: asset)
                    return file
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
            }
            try? FileManager.default.removeItem(at: file)
            guard (300..<400).contains(response.statusCode),
                let location = response.value(forHTTPHeaderField: "Location"),
                let next = URL(string: location, relativeTo: url)?.absoluteURL,
                let host = next.host?.lowercased(), next.scheme == "https",
                host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
            else { throw ReaderError.message("语义模型下载失败（HTTP \(response.statusCode)）。") }
            url = next
        }
        throw ReaderError.message("语义模型下载发生了过多跳转。")
    }

    static func install(in parent: URL, transport: any HTTPTransport) async throws {
        let files = FileManager.default
        var staging = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try staging.setResourceValues(properties)
        for asset in assets {
            let destination = staging.appendingPathComponent(asset.path)
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let downloaded = try await download(asset, transport: transport)
            defer { try? files.removeItem(at: downloaded) }
            try files.moveItem(at: downloaded, to: destination)
        }
        let compiled = try await MLModel.compileModel(at: staging.appendingPathComponent(package))
        defer { try? files.removeItem(at: compiled) }
        try Task.checkCancellation()
        try files.moveItem(at: compiled, to: staging.appendingPathComponent(model))
        try files.removeItem(at: staging.appendingPathComponent(package))
        let destination = parent.appendingPathComponent(revision, isDirectory: true)
        // Another process can install the same immutable revision while compilation is in flight.
        do { try files.moveItem(at: staging, to: destination) } catch {
            if !isInstalled(at: destination) { throw error }
        }
    }

    static func isInstalled(at folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(model).path)
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent(tokenizer).path)
    }
}
