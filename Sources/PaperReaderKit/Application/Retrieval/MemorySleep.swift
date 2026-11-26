import CryptoKit
import Foundation

/// Model summaries are derivative. Every input in the model call must still be valid.
public struct MemorySleepEdition: Codable, Equatable, Sendable {
    public struct Connection: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case duplicate, related, compare, superseded, refine }
        public let kind: Kind
        public let members: [UUID]
        public var summary: String?
        public var inputs: [UUID]?
        public var current: UUID?
    }

    public private(set) var revision: UUID?
    public private(set) var connections: [Connection] = []
    private var versions: [UUID: Data] = [:]
    private var reviewed: Set<UUID> = []
    private var retryOnce: Set<UUID>?
    public var hasPendingReview: Bool { reviewed.count < versions.count }

    public init() {}

    static func signature(_ item: MemoryItem) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: try encoder.encode(item)))
    }

    public func liveConnections(for items: [MemoryItem]) -> [Connection] {
        guard !connections.isEmpty else { return [] }
        let valid = Set(
            items.compactMap { item -> UUID? in
                guard !item.deleted, let saved = versions[item.id], (try? Self.signature(item)) == saved else {
                    return nil
                }
                return item.id
            })
        return connections.compactMap {
            guard Set($0.inputs ?? $0.members).isSubset(of: valid) else { return nil }
            return $0
        }
    }

    /// A related topic can share the current decision. Resolve every obsolete ID to the
    /// terminal decision before ranking so recalling the oldest wording cannot revive it.
    public func recallConnections(for items: [MemoryItem]) -> [Connection] {
        let live = liveConnections(for: items)
        let changes = live.filter { $0.kind == .superseded && $0.current != nil }
        guard !changes.isEmpty else { return live }
        let byCurrent = Dictionary(grouping: changes) { $0.current! }
        let obsolete = Set(changes.flatMap { change in change.members.filter { $0 != change.current } })
        var result = live.filter { $0.kind != .superseded && obsolete.isDisjoint(with: $0.members) }
        for current in byCurrent.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !obsolete.contains(current) {
            guard let latest = byCurrent[current]?.last else { continue }
            var pending = [current]
            var members = Set([current])
            var inputs = Set<UUID>()
            while let id = pending.popLast() {
                for step in byCurrent[id] ?? [] {
                    inputs.formUnion(step.inputs ?? step.members)
                    for earlier in step.members where members.insert(earlier).inserted { pending.append(earlier) }
                }
            }
            result.append(
                Connection(
                    kind: .superseded, members: members.sorted { $0.uuidString < $1.uuidString },
                    summary: latest.summary, inputs: Array(inputs), current: current))
        }
        return result
    }

    struct Candidate: Encodable {
        let id: UUID
        let text: String
        let preference: ReaderPreference?
        let protected: Bool
        let source: String
        let recorded: Date
    }

    static func eligible(_ state: LibraryState) -> [MemoryItem] {
        let origins = ResearchMemoryOrigins(state: state, excluding: [])
        func order(_ item: MemoryItem) -> String {
            switch item.preference?.scope {
            case nil, .library: return item.isResponsePreference ? "1" : "0"
            case .paper(let id): return "p" + id.uuidString
            case .shelf(let id): return "s" + id.uuidString
            }
        }
        return state.memories.filter { !$0.isResponsePreference && origins.resolve($0) != nil }.sorted {
            let left = order($0)
            let right = order($1)
            if left != right { return left < right }
            return $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
        }
    }

    mutating func reconcile(_ items: [MemoryItem]) throws {
        let next = try Dictionary(uniqueKeysWithValues: items.map { ($0.id, try Self.signature($0)) })
        guard next != versions else { return }
        let revised = liveConnections(for: items)
        let connectionsBefore = connections
        if revised != connections { revision = UUID() }
        connections = revised
        reviewed = reviewed.filter { next[$0] != nil && next[$0] == versions[$0] }
        let retries = retryOnce?.filter { next[$0] != nil && next[$0] == versions[$0] }
        retryOnce = retries?.isEmpty == false ? retries : nil
        // A changed input invalidates the generated statements that used it, even when the
        // surviving members had no edits. Let the next idle batch reconstruct those records.
        for group in connectionsBefore where !revised.contains(group) {
            reviewed.subtract(group.members)
        }
        versions = next
    }

    func batch(_ items: [MemoryItem], state: LibraryState, semantic: SemanticPassageIndex? = nil) async -> [Candidate] {
        guard hasPendingReview else { return [] }
        let remaining = items.filter { !reviewed.contains($0.id) }
        guard let first = remaining.first else { return [] }
        let changed = Array(remaining.filter { $0.preference?.scope == first.preference?.scope }.prefix(20))
        let earlier = items.filter { reviewed.contains($0.id) && $0.preference?.scope == first.preference?.scope }
        var semanticScores: [UUID: Double] = [:]
        if let semantic, !changed.isEmpty, !earlier.isEmpty {
            let passages = earlier.map {
                SemanticPassage(sourceID: $0.id, text: String($0.text.prefix(400)))
            }
            let query = String(changed.map(\.text).joined(separator: " ").prefix(1_600))
            let matches =
                (try? await semantic.matches(
                    query, passages: passages, allowed: Set(passages.map(\.sourceID)), limit: 16)) ?? []
            for (rank, match) in matches.enumerated() {
                semanticScores[match.passage.sourceID] = Double(matches.count - rank) / Double(max(1, matches.count))
            }
        }
        let anchors = Self.anchorOrder(changed: changed, earlier: earlier, semanticScores: semanticScores)
        let selected = changed + anchors
        let origins = ResearchMemoryOrigins(state: state, for: selected)
        return selected.map { item in
            let source: String
            switch origins.resolve(item) {
            case .reader: source = "reader"
            case .paper(let id): source = "paper/" + id.uuidString
            case nil: source = "unknown"
            }
            return Candidate(
                id: item.id, text: String(item.text.prefix(400)), preference: item.preference,
                protected: item.userEdited || item.isResponsePreference, source: source, recorded: item.createdAt)
        }
    }

    /// Lexical and semantic recall both nominate anchors. Semantic neighbours come first so a
    /// Chinese memory can meet its English paraphrase during idle consolidation.
    static func anchorOrder(
        changed: [MemoryItem], earlier: [MemoryItem], semanticScores: [UUID: Double]
    ) -> [MemoryItem] {
        let terms = changed.reduce(into: Set<String>()) { $0.formUnion(Retriever.expandedTokens($1.text)) }
        let scored = earlier.map { item -> (item: MemoryItem, semantic: Double, overlap: Int) in
            (
                item, semanticScores[item.id] ?? 0,
                Retriever.expandedTokens(item.text).intersection(terms).count
            )
        }
        return scored.sorted { left, right in
            if (left.semantic > 0) != (right.semantic > 0) { return left.semantic > 0 }
            if left.semantic != right.semantic { return left.semantic > right.semantic }
            if left.overlap != right.overlap { return left.overlap > right.overlap }
            if left.item.createdAt != right.item.createdAt { return left.item.createdAt > right.item.createdAt }
            return left.item.id.uuidString < right.item.id.uuidString
        }.prefix(8).map(\.item)
    }

    /// A service may return a malformed response or suggest only nonexistent records.
    /// Give each unchanged input one additional attempt, even after an app restart.
    private mutating func finishReview(_ batch: [Candidate], accepted: Bool) {
        let pending = Set(batch.map(\.id)).subtracting(reviewed)
        var retries = retryOnce ?? []
        let finished = accepted ? pending : pending.intersection(retries)
        reviewed.formUnion(finished)
        retries.formUnion(pending.subtracting(finished))
        retries.subtract(finished)
        retryOnce = retries.isEmpty ? nil : retries
    }

    mutating func accept(_ response: String, batch: [Candidate], prior: [Connection]) {
        struct Report: Decodable {
            let groups: [Connection]
            let retire: [[UUID]]?
        }
        guard let parsed = try? JSONDecoder().decode(Report.self, from: Data(response.utf8)) else {
            finishReview(batch, accepted: false)
            return
        }
        let available = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
        let before = connections
        let retirements = (parsed.retire ?? []).prefix(12).map { Set($0) }
        connections.removeAll { entry in
            prior.contains(entry) && retirements.contains(Set(entry.members))
        }
        var accepted = connections.count != before.count || (parsed.groups.isEmpty && retirements.isEmpty)
        let inputs = Set(batch.map(\.id) + prior.flatMap { $0.inputs ?? $0.members }).sorted {
            $0.uuidString < $1.uuidString
        }
        for group in parsed.groups.prefix(12) {
            let members = Array(Set(group.members)).sorted { $0.uuidString < $1.uuidString }
            guard (group.kind == .refine ? 1...1 : 2...6).contains(members.count),
                let summary = group.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                !summary.isEmpty, summary.count <= 240,
                let first = available[members[0]],
                members.allSatisfy({
                    available[$0] != nil && available[$0]?.preference?.scope == first.preference?.scope
                }),
                group.kind != .refine || first.protected == false
            else { continue }
            let updated = Set(members)
            if group.kind == .superseded {
                guard let id = group.current, let current = available[id], members.contains(id),
                    members.allSatisfy({
                        $0 == id || (available[$0]?.protected == false && available[$0]!.recorded < current.recorded)
                    })
                else { continue }
                // An older entry has only one successor. Replacing that decision requires
                // retiring its visible relation. B -> C can extend A -> B independently.
                let outgoing = updated.subtracting([id])
                guard
                    !connections.contains(where: { prior in
                        prior.kind == .superseded && prior.current != id
                            && !outgoing.isDisjoint(with: prior.members.filter { $0 != prior.current })
                    })
                else { continue }
            }
            connections.removeAll { existing in
                if existing.kind == .superseded {
                    return group.kind == .superseded && existing.current == group.current
                        && Set(existing.members) == updated
                }
                return group.kind != .superseded && !updated.isDisjoint(with: existing.members)
            }
            connections.append(
                Connection(
                    kind: group.kind, members: members, summary: summary, inputs: inputs,
                    current: group.current))
            accepted = true
        }
        if before != connections { revision = UUID() }
        finishReview(batch, accepted: accepted)
    }
}

public actor MemorySleepStore {
    public struct ReviewInput: Sendable {
        public let json: String
        fileprivate let versions: [UUID: Data]

        public func isCurrent(in state: LibraryState, excluding pending: Set<UUID> = []) -> Bool {
            let items = state.memories.filter { versions[$0.id] != nil }
            let origins = ResearchMemoryOrigins(state: state, excluding: pending, for: items)
            return items.count == versions.count
                && items.allSatisfy {
                    origins.resolve($0) != nil && (try? MemorySleepEdition.signature($0)) == versions[$0.id]
                }
        }
    }

    private let store: LibraryStore
    private let semantic: SemanticPassageIndex?
    public init(store: LibraryStore, semantic: SemanticPassageIndex? = nil) {
        self.store = store
        self.semantic = semantic
    }
    public typealias Review = @Sendable (ReviewInput) async throws -> String

    public func load() async throws -> MemorySleepEdition {
        guard let data = try await store.readResearchCheckpoint(.sleep),
            let edition = try? JSONDecoder().decode(MemorySleepEdition.self, from: data)
        else { return MemorySleepEdition() }
        return edition
    }

    public func run(review: Review? = nil) async throws -> MemorySleepEdition {
        guard let (state, revision) = await store.committedResearchState() else { return MemorySleepEdition() }
        let previousBytes = try await store.readResearchCheckpoint(.sleep)
        let previous =
            previousBytes.flatMap { try? JSONDecoder().decode(MemorySleepEdition.self, from: $0) }
            ?? MemorySleepEdition()
        var edition = previous
        let items = MemorySleepEdition.eligible(state)
        try edition.reconcile(items)
        let batch = await edition.batch(items, state: state, semantic: semantic)
        if let review, !batch.isEmpty {
            try Task.checkCancellation()
            struct Input: Encodable {
                let records: [MemorySleepEdition.Candidate]
                let active: [MemorySleepEdition.Connection]
            }
            let ids = Set(batch.map(\.id))
            let prior = Array(edition.connections.filter { Set($0.members).isSubset(of: ids) }.prefix(12))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let active = prior.map { connection in
                var visible = connection
                visible.inputs = nil
                return visible
            }
            let input = try encoder.encode(Input(records: batch, active: active))
            let dependencies = ids.union(prior.flatMap { $0.inputs ?? $0.members })
            let versions = try Dictionary(
                uniqueKeysWithValues: items.filter { dependencies.contains($0.id) }.map {
                    ($0.id, try MemorySleepEdition.signature($0))
                })
            let result = try await review(ReviewInput(json: String(decoding: input, as: UTF8.self), versions: versions))
            edition.accept(result, batch: batch, prior: prior)
        }
        try Task.checkCancellation()
        if edition != previous {
            let payload = try JSONEncoder().encode(edition)
            guard
                try await store.publishResearchCheckpoint(
                    payload, revision: revision, table: .sleep, previousPayload: previousBytes)
            else {
                throw ReaderError.message("整理期间来源有更新，将按新来源重新整理。")
            }
        }
        return edition
    }
}
