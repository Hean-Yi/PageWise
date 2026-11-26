import Accelerate
import CryptoKit
import Foundation

public enum SemanticTextRole: Sendable { case query, passage }
public protocol SemanticTextEncoder: Sendable {
    var identifier: String { get }
    func isInstalled() async -> Bool
    func retrievalQuery(_ text: String) async throws -> (vector: [Float], minimum: Float)?
    func encode(_ texts: [String], as role: SemanticTextRole) async throws -> [[Float]]
}

extension SemanticTextEncoder {
    public func isInstalled() async -> Bool { true }

    public func retrievalQuery(_ text: String) async throws -> (vector: [Float], minimum: Float)? {
        try await encode([text], as: .query).first.map { ($0, 0.82) }
    }
}

public enum RetrievalMode: Sendable { case lexical, semantic, hybrid }

public struct SemanticPassage: Hashable, Sendable {
    public let sourceID: UUID
    public let chunk: Int
    public let text: String

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sourceID)
        hasher.combine(chunk)
        hasher.combine(text)
    }

    public init(sourceID: UUID, chunk: Int = 0, text: String) {
        self.sourceID = sourceID
        self.chunk = chunk
        self.text = text
    }
}

public struct SemanticMatch: Sendable {
    public let passage: SemanticPassage
    public let score: Float
}

/// One instance per library and evidence class. The caller supplies the full authoritative
/// corpus, then restricts eligible sources for this query. SQLite never supplies source prose.
public actor SemanticPassageIndex {
    private let encoder: (any SemanticTextEncoder)?
    private let disk: SemanticVectorCache?
    private let writer = UUID().uuidString
    private var opened = false
    private var passages: [SemanticPassage] = []
    private var keys: [SemanticPassage: Data] = [:]
    private var vectors: [Data: [Float]] = [:]
    private var generation: UInt64 = 0
    private var warmer: Task<Void, Error>?
    private let minimumScore: Float?

    public init(encoder: (any SemanticTextEncoder)? = nil, cacheURL: URL? = nil, minimumScore: Float? = nil) {
        self.encoder = encoder
        self.disk = cacheURL.map(SemanticVectorCache.init)
        self.minimumScore = minimumScore
    }

    private func reconcile(_ next: [SemanticPassage], encoderID: String) {
        if !opened {
            vectors = (try? disk?.load(writer: writer)) ?? [:]
            opened = true
        } else if next == passages {
            return
        }
        warmer?.cancel()
        warmer = nil
        generation &+= 1
        passages = next
        var wanted: [SemanticPassage: Data] = [:]
        for p in next {
            wanted[p] =
                keys[p] ?? Data(SHA256.hash(data: Data("\(encoderID)/v1/\(p.sourceID)/\(p.chunk)/\(p.text)".utf8)))
        }
        keys = wanted
        let stale = Set(vectors.keys).subtracting(wanted.values)
        if !stale.isEmpty {
            for key in stale { vectors.removeValue(forKey: key) }
            try? disk?.update(adding: [:], removing: stale, writer: writer)
        }
    }

    /// A clean installation can skip creation of the corpus entirely. On uninstall, erase
    /// existing derived vectors without walking the paper or note texts.
    public func isAvailable() async -> Bool {
        guard let encoder else { return false }
        if await encoder.isInstalled() { return true }
        if !passages.isEmpty || (!opened && disk.map { FileManager.default.fileExists(atPath: $0.url.path) } == true) {
            reconcile([], encoderID: encoder.identifier)
        }
        return false
    }

    public func isWarm() -> Bool {
        !keys.isEmpty && vectors.count >= keys.count
    }

    public func removeSources(_ ids: Set<UUID>) {
        guard opened, !ids.isEmpty, let encoder, passages.contains(where: { ids.contains($0.sourceID) }) else { return }
        reconcile(passages.filter { !ids.contains($0.sourceID) }, encoderID: encoder.identifier)
    }

    public func prepare(_ passages: [SemanticPassage]) async throws {
        guard let encoder else { return }
        reconcile(passages, encoderID: encoder.identifier)
        let version = generation
        guard await encoder.isInstalled(), version == generation else { return }
        try await warmup(encoder, version: version).value
    }

    private func warmup(_ encoder: any SemanticTextEncoder, version: UInt64) -> Task<Void, Error> {
        if let warmer { return warmer }
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await self.fill(encoder, generation: version)
            } catch {
                await self.finished(version)
                throw error
            }
            await self.finished(version)
        }
        warmer = task
        return task
    }

    private func fill(_ encoder: any SemanticTextEncoder, generation version: UInt64) async throws {
        let missing = passages.filter { keys[$0].flatMap { vectors[$0] } == nil }
        for start in stride(from: 0, to: missing.count, by: 4) {
            try Task.checkCancellation()
            guard version == generation else { return }
            let batch = missing[start..<min(start + 4, missing.count)].filter {
                keys[$0].flatMap { vectors[$0] } == nil
            }
            guard !batch.isEmpty else { continue }
            let output = try await encoder.encode(batch.map(\.text), as: .passage)
            try Task.checkCancellation()
            guard version == generation, output.count == batch.count else { return }
            var added: [Data: [Float]] = [:]
            for (passage, raw) in zip(batch, output) {
                guard let key = keys[passage], let unit = Self.unit(raw) else { continue }
                vectors[key] = unit
                added[key] = unit
            }
            try? disk?.update(adding: added, removing: [], writer: writer)
            await Task.yield()
        }
    }

    public func matches(_ query: String, passages: [SemanticPassage], allowed: Set<UUID>, limit: Int) async throws
        -> [SemanticMatch]
    {
        guard let encoder else { return [] }
        reconcile(passages, encoderID: encoder.identifier)
        let version = generation
        guard !allowed.isEmpty, limit > 0, !query.isEmpty, await encoder.isInstalled(), version == generation else {
            return []
        }
        do {
            if vectors.count < keys.count {
                // Never make the first lexical result wait for model loading. Start the warmup
                // and serve the current lexical result; later queries see the semantic vectors.
                _ = warmup(encoder, version: version)
            }
            guard !vectors.isEmpty, version == generation,
                let encoded = try await encoder.retrievalQuery(String(query.prefix(1_600))),
                let queryVector = Self.unit(encoded.vector), version == generation
            else { return [] }
            var best: [UUID: SemanticMatch] = [:]
            for p in passages where allowed.contains(p.sourceID) {
                try Task.checkCancellation()
                guard let key = keys[p], let vector = vectors[key], vector.count == queryVector.count else { continue }
                let score = vDSP.dot(queryVector, vector)
                guard score >= (minimumScore ?? encoded.minimum) else { continue }
                if let current = best[p.sourceID],
                    current.score > score || (current.score == score && current.passage.chunk <= p.chunk)
                {
                    continue
                }
                best[p.sourceID] = SemanticMatch(passage: p, score: score)
            }
            let ranked = best.values.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.passage.sourceID.uuidString < $1.passage.sourceID.uuidString
            }
            return Array(ranked.prefix(limit))
        } catch {
            try Task.checkCancellation()
            return []
        }
    }

    private func finished(_ version: UInt64) {
        if version == generation { warmer = nil }
    }

    private static func unit(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.count <= 4096 else { return nil }
        let norm = sqrt(vDSP.sumOfSquares(vector))
        guard norm.isFinite, norm > 0 else { return nil }
        return vDSP.divide(vector, norm)
    }

    public nonisolated static func fused(lexical: [UUID], semantic: [UUID], lexicalSupport: [UUID: Double] = [:])
        -> [UUID]
    {
        if semantic.isEmpty { return lexical }
        if lexical.isEmpty { return semantic }
        var scores: [UUID: Double] = [:]
        for (rank, id) in lexical.enumerated() {
            scores[id, default: 0] += (lexicalSupport[id] ?? 1) / Double(31 + rank)
        }
        for (rank, id) in semantic.enumerated() { scores[id, default: 0] += 1.0 / Double(31 + rank) }
        let exactOrder = Dictionary(uniqueKeysWithValues: lexical.enumerated().map { ($1, $0) })
        return scores.keys.sorted {
            if scores[$0] != scores[$1] { return scores[$0]! > scores[$1]! }
            return (exactOrder[$0] ?? Int.max) < (exactOrder[$1] ?? Int.max)
        }
    }
}
