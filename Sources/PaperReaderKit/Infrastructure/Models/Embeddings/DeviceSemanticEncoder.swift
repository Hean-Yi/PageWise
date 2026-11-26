import Accelerate
import CoreML
import Foundation
import SentencePiece

public actor DeviceSemanticEncoder: SemanticTextEncoder {
    public static let shared = DeviceSemanticEncoder(directory: E5ModelResources.defaultDirectory)
    public nonisolated let identifier = E5ModelResources.revision
    private let directory: URL
    private let transport: any HTTPTransport
    private var runtime: Runtime?
    private var installation: Task<Void, Error>?

    public init(directory: URL, transport: any HTTPTransport = NetworkTransport()) {
        self.directory = directory
        self.transport = transport
    }

    public func isInstalled() async -> Bool {
        E5ModelResources.isInstalled(at: directory.appendingPathComponent(identifier))
    }

    public func install() async throws {
        if let installation { return try await installation.value }
        if E5ModelResources.isInstalled(at: directory.appendingPathComponent(identifier)) { return }
        let job = Task { [directory, transport] in
            try await E5ModelResources.install(in: directory, transport: transport)
        }
        installation = job
        defer { installation = nil }
        try await job.value
    }

    public func cancelInstall() { installation?.cancel() }

    public func uninstall() async throws {
        // A bundled release model is immutable and must never be deleted by a settings action.
        guard E5ModelResources.bundledParent == nil else { return }
        if let job = installation {
            job.cancel()
            _ = await job.result
        }
        runtime = nil
        let folder = directory.appendingPathComponent(identifier)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    public func encode(_ texts: [String], as role: SemanticTextRole) async throws -> [[Float]] {
        try Task.checkCancellation()
        let folder = directory.appendingPathComponent(identifier)
        guard E5ModelResources.isInstalled(at: folder) else { throw ReaderError.message("请先下载语义检索模型。") }
        if runtime == nil { runtime = try Runtime(folder: folder) }
        guard let runtime else { throw ReaderError.message("语义模型暂时无法加载。") }
        var output: [[Float]] = []
        for text in texts {
            try Task.checkCancellation()
            output.append(try autoreleasepool { try runtime.vector(text, as: role) })
        }
        return output
    }

    private final class Runtime {
        let model: MLModel
        let tokenizer: SentencePiece
        let queryPrefix: [Int32]
        let passagePrefix: [Int32]

        init(folder: URL) throws {
            let configuration = MLModelConfiguration()
            #if os(macOS) && arch(arm64)
                // On Apple silicon this fixed-length encoder starts much faster on CPU, with comparable warm latency.
                configuration.computeUnits = .cpuOnly
            #else
                configuration.computeUnits = .all
            #endif
            model = try MLModel(
                contentsOf: folder.appendingPathComponent(E5ModelResources.model), configuration: configuration)
            let tokenizerURL = folder.appendingPathComponent(E5ModelResources.tokenizer)
            if let asset = E5ModelResources.assets.first(where: { $0.path == E5ModelResources.tokenizer }) {
                try E5ModelResources.verify(tokenizerURL, asset: asset)
            }
            tokenizer = SentencePiece(file: tokenizerURL.path)
            queryPrefix = Self.ids("query:", tokenizer)
            passagePrefix = Self.ids("passage:", tokenizer)
            guard !queryPrefix.isEmpty, !passagePrefix.isEmpty else { throw ReaderError.message("语义模型分词器无法读取。") }
        }

        static func ids(_ text: String, _ tokenizer: SentencePiece) -> [Int32] {
            // XLM-R reserves 0/1/2/3 for <s>, <pad>, </s>, <unk>. Other SPM IDs are shifted by one.
            tokenizer.encode(text.replacingOccurrences(of: "\0", with: " ")).map { $0.id == 0 ? 3 : $0.id + 1 }
        }

        func vector(_ text: String, as role: SemanticTextRole) throws -> [Float] {
            let prefix = role == .query ? queryPrefix : passagePrefix
            let pieces = Self.ids(text, tokenizer)
            guard !pieces.isEmpty else { throw ReaderError.message("没有可编码的文字。") }
            let capacity = 256 - 2 - prefix.count
            var sum = [Float](repeating: 0, count: 384)
            for start in stride(from: 0, to: pieces.count, by: capacity) {
                try Task.checkCancellation()
                let end = min(start + capacity, pieces.count)
                let tokens = [0] + prefix + pieces[start..<end] + [2]
                let window = try prediction(tokens)
                for i in sum.indices { sum[i] += window[i] * Float(end - start) }
            }
            let norm = sqrt(vDSP.sumOfSquares(sum))
            guard norm.isFinite, norm > 0 else { throw ReaderError.message("语义模型返回了无效向量。") }
            return vDSP.divide(sum, norm)
        }

        func prediction(_ tokens: [Int32]) throws -> [Float] {
            let ids = try MLMultiArray(shape: [1, 256], dataType: .int32)
            let mask = try MLMultiArray(shape: [1, 256], dataType: .int32)
            ids.withUnsafeMutableBytes { bytes, _ in
                let buffer = bytes.bindMemory(to: Int32.self)
                for i in 0..<256 { buffer[i] = i < tokens.count ? tokens[i] : 1 }
            }
            mask.withUnsafeMutableBytes { bytes, _ in
                let buffer = bytes.bindMemory(to: Int32.self)
                for i in 0..<256 { buffer[i] = i < tokens.count ? 1 : 0 }
            }
            let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
            guard let output = try model.prediction(from: input).featureValue(for: "embeddings")?.multiArrayValue,
                output.count == 384
            else { throw ReaderError.message("语义模型输出维度不符。") }
            return (0..<384).map { output[$0].floatValue }
        }
    }
}
