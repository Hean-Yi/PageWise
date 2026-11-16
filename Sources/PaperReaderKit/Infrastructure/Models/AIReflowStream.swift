import Foundation

actor AIReflowStream {
    private let evidence: AIReflowEvidence
    private let requestID: UUID
    private let windowID: UUID
    private let configurationDigest: String
    private let acceptedPlan: AIReflowPlan?
    private let committed: Set<UUID>
    private let onPlan: @Sendable (AIReflowPlan) async throws -> Void
    private let onDraft: @Sendable (TextBlock, String) async throws -> Void
    private let onBlock: @Sendable (BilingualBlock, [UUID]) async throws -> Void
    private var previous = Data()
    private var pending = Data()
    private var sequence = 0
    private var plan: AIReflowPlan?
    private var index = 0
    private var current: (block: TextBlock, markers: [String: String], translates: Bool)?
    private var translation = ""
    private var usedObjects = Set<String>()
    private var ended = false
    private var paused = false
    private var translatedCount = 0
    private let translationBlockLimit: Int?
    private let compactEvents: Bool

    init(
        evidence: AIReflowEvidence, requestID: UUID, windowID: UUID, configurationDigest: String,
        acceptedPlan: AIReflowPlan?, committed: Set<UUID>,
        translationBlockLimit: Int? = nil,
        compactEvents: Bool = false,
        onPlan: @escaping @Sendable (AIReflowPlan) async throws -> Void,
        onDraft: @escaping @Sendable (TextBlock, String) async throws -> Void,
        onBlock: @escaping @Sendable (BilingualBlock, [UUID]) async throws -> Void
    ) throws {
        self.evidence = evidence
        self.requestID = requestID
        self.windowID = windowID
        self.configurationDigest = configurationDigest
        self.acceptedPlan = acceptedPlan
        self.committed = committed
        self.translationBlockLimit = translationBlockLimit
        self.compactEvents = compactEvents
        self.onPlan = onPlan
        self.onDraft = onDraft
        self.onBlock = onBlock
        if let acceptedPlan {
            guard acceptedPlan.version == 1, acceptedPlan.windowID == windowID,
                acceptedPlan.evidenceDigest == evidence.digest,
                acceptedPlan.requestConfigurationDigest == configurationDigest,
                Set(acceptedPlan.blocks.map(\.id)).count == acceptedPlan.blocks.count,
                Set(acceptedPlan.blocks.prefix(committed.count).map(\.id)) == committed
            else { throw AIReflowEvidence.invalid() }
            try validate(acceptedPlan.blocks)
        } else if !committed.isEmpty {
            throw AIReflowEvidence.invalid()
        }
    }

    func consume(_ output: String) async throws {
        let bytes = Data(output.utf8)
        // A new combining scalar or ZWJ can extend the previous final Character.
        // Stream offsets and integrity therefore use exact bytes, never grapheme counts
        // or String's canonically equivalent prefix comparison.
        guard bytes.starts(with: previous), bytes.count <= 2_000_000 else { throw AIReflowEvidence.invalid() }
        pending.append(contentsOf: bytes.dropFirst(previous.count))
        previous = bytes
        while let newline = pending.firstIndex(of: 10) {
            guard let decoded = String(data: pending[..<newline], encoding: .utf8) else {
                throw AIReflowEvidence.invalid()
            }
            let line = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            guard !line.isEmpty else { throw AIReflowEvidence.invalid() }
            try await event(line)
        }
        guard pending.count <= 65_536 else { throw AIReflowEvidence.invalid() }
    }

    func finish() async throws {
        // A final complete JSON record need not end in LF; an incomplete JSON record fails decoding.
        guard let line = String(data: pending, encoding: .utf8) else { throw AIReflowEvidence.invalid() }
        if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pending.removeAll()
            try await event(line)
        }
        guard ended, current == nil, let plan, index == plan.blocks.count || paused else {
            throw AIReflowEvidence.invalid()
        }
    }

    /// Native JSON-mode framing supplies individual complete objects, including pretty printing.
    func consumeEvent(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else { throw AIReflowEvidence.invalid() }
        try await event(text)
    }

    private func event(_ line: String) async throws {
        guard !ended, line.utf8.count <= 65_536, sequence < 4096,
            let data = line.data(using: .utf8),
            var value = try Self.object(from: data) as? [String: Any],
            let type = value["type"] as? String
        else { throw AIReflowEvidence.invalid() }
        // Only explicitly negotiated compact events inherit an already verified response identity.
        if compactEvents, plan != nil, value["v"] == nil, value["request_id"] == nil, value["window_id"] == nil {
            value["v"] = 1
            value["request_id"] = requestID.uuidString
            value["window_id"] = windowID.uuidString
        }
        if compactEvents, ["window_pause", "window_end"].contains(type), value["block_count"] == nil, let plan {
            value["block_count"] = plan.blocks.count
        }
        let common: Set<String> = ["v", "request_id", "window_id", "seq", "type"]
        let extra: Set<String>
        switch type {
        case "window_plan": extra = ["blocks", "dispositions", "carry"]
        case "block_start", "block_end", "window_resume": extra = ["block_index"]
        case "translation_delta": extra = ["block_index", "parts"]
        case "window_end", "window_pause": extra = ["block_count"]
        default: throw AIReflowEvidence.invalid()
        }
        try Self.keys(value, common.union(extra))
        let header = try Self.decode(Header.self, from: JSONSerialization.data(withJSONObject: value))
        guard header.v == 1, header.requestID == requestID, header.windowID == windowID,
            header.seq == sequence
        else { throw AIReflowEvidence.invalid() }
        sequence += 1
        try Task.checkCancellation()
        switch type {
        case "window_plan": try await receivePlan(value)
        case "window_resume":
            guard plan == nil, sequence == 1, let acceptedPlan,
                try Self.integer(value, "block_index") == committed.count
            else { throw AIReflowEvidence.invalid() }
            plan = acceptedPlan
            index = committed.count
        case "block_start":
            guard let plan, current == nil, index < plan.blocks.count,
                try Self.integer(value, "block_index") == index
            else { throw AIReflowEvidence.invalid() }
            current = try evidence.assemble(plan.blocks[index])
            if current?.translates == true, ![.title, .heading].contains(plan.blocks[index].kind),
                let translationBlockLimit, translatedCount >= translationBlockLimit
            {
                throw AIReflowEvidence.invalid()
            }
            translation = ""
            usedObjects = []
        case "translation_delta": try await delta(value)
        case "block_end":
            guard let plan, let current, try Self.integer(value, "block_index") == index else {
                throw AIReflowEvidence.invalid()
            }
            let result = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.translates {
                guard !result.isEmpty, usedObjects == Set(current.markers.keys) else {
                    throw AIReflowEvidence.invalid()
                }
                try current.block.richContent?.validate(result)
            } else if !result.isEmpty {
                throw AIReflowEvidence.invalid()
            }
            try await onBlock(
                BilingualBlock(block: current.block, translation: current.translates ? result : nil),
                plan.blocks[index].sourceIDs)
            if current.translates, ![.title, .heading].contains(plan.blocks[index].kind) { translatedCount += 1 }
            self.current = nil
            index += 1
        case "window_end":
            guard let plan, current == nil, index == plan.blocks.count,
                try Self.integer(value, "block_count") == plan.blocks.count
            else { throw AIReflowEvidence.invalid() }
            ended = true
        case "window_pause":
            guard translationBlockLimit != nil, let plan, current == nil,
                index > committed.count, index < plan.blocks.count,
                try Self.integer(value, "block_count") == plan.blocks.count
            else { throw AIReflowEvidence.invalid() }
            paused = true
            ended = true
        default: throw AIReflowEvidence.invalid()
        }
    }

    private func receivePlan(_ value: [String: Any]) async throws {
        guard plan == nil, sequence == 1,
            let rawBlocks = value["blocks"] as? [[String: Any]], !rawBlocks.isEmpty, rawBlocks.count <= 128,
            let dispositions = value["dispositions"] as? [Any], dispositions.isEmpty,
            let carry = value["carry"] as? [Any], carry.isEmpty
        else { throw AIReflowEvidence.invalid() }
        var blocks: [AIReflowPlan.Block] = []
        for (index, raw) in rawBlocks.enumerated() {
            try Self.keys(raw, ["block_index", "kind", "source_segments", "object_refs"])
            guard try Self.integer(raw, "block_index") == index,
                let kindString = raw["kind"] as? String, let kind = AIReflowPlan.Kind(rawValue: kindString),
                let segments = raw["source_segments"] as? [[String: Any]], !segments.isEmpty,
                let refs = raw["object_refs"] as? [String]
            else { throw AIReflowEvidence.invalid() }
            var mapped: [AIReflowPlan.SourceSegment] = []
            for segment in segments {
                try Self.keys(segment, ["source_id", "start_utf16", "end_utf16"])
                guard let rawID = segment["source_id"] as? String, let id = evidence.sourceID(rawID) else {
                    throw AIReflowEvidence.invalid()
                }
                mapped.append(
                    .init(
                        sourceID: id, startUTF16: try Self.integer(segment, "start_utf16"),
                        endUTF16: try Self.integer(segment, "end_utf16")))
            }
            blocks.append(
                .init(
                    id: acceptedPlan?.blocks.indices.contains(index) == true ? acceptedPlan!.blocks[index].id : UUID(),
                    kind: kind, sourceSegments: mapped, objectRefs: refs))
        }
        try validate(blocks)
        let proposed = AIReflowPlan(
            version: 1, windowID: windowID, evidenceDigest: evidence.digest,
            requestConfigurationDigest: configurationDigest, blocks: blocks)
        if let acceptedPlan, acceptedPlan != proposed { throw AIReflowEvidence.invalid() }
        // Await durable acceptance before any source/translation can reach a publication callback.
        try await onPlan(proposed)
        plan = proposed
        index = committed.count
    }

    private nonisolated func validate(_ blocks: [AIReflowPlan.Block]) throws {
        let ids = blocks.flatMap(\.sourceIDs)
        let originalIDs = evidence.sources.map { $0.block.id }
        guard ids.count == originalIDs.count, Set(ids) == Set(originalIDs) else {
            throw AIReflowEvidence.invalid()
        }
        let ranks = Dictionary(
            uniqueKeysWithValues: evidence.orderGroups.enumerated().flatMap { rank, group in
                group.map { ($0, rank) }
            })
        let orderedRanks = ids.compactMap { ranks[$0] }
        guard orderedRanks == orderedRanks.sorted() else { throw AIReflowEvidence.invalid() }
        let byID = Dictionary(uniqueKeysWithValues: evidence.sources.map { ($0.block.id, $0) })
        for block in blocks {
            guard !block.sourceSegments.isEmpty else { throw AIReflowEvidence.invalid() }
            if block.sourceIDs.count > 1,
                block.sourceIDs.contains(where: { byID[$0]?.block.reflowOrderGroup != nil }),
                block.sourceIDs.reduce(0, { $0 + (byID[$1]?.block.text.utf16.count ?? 0) }) > 1_600
            {
                throw AIReflowEvidence.invalid()
            }
            var refs: [String] = []
            for segment in block.sourceSegments {
                guard let source = byID[segment.sourceID], segment.startUTF16 == 0,
                    segment.endUTF16 == source.block.text.utf16.count
                else { throw AIReflowEvidence.invalid() }
                if block.sourceSegments.count > 1 {
                    guard source.kind == .paragraph, source.translates, block.kind == .paragraph,
                        source.objects.allSatisfy({ $0.marker != nil })
                    else { throw AIReflowEvidence.invalid() }
                } else if source.kind == .paragraph {
                    let ordinary: [AIReflowPlan.Kind] = [.paragraph, .title, .heading, .listItem, .substantiveFootnote]
                    let modelTypes: [AIReflowPlan.Kind] = [.frontMatter, .nonContent, .bibliography, .code]
                    guard
                        ordinary.contains(block.kind)
                            || (source.block.reflowOrderGroup != nil && source.objects.isEmpty
                                && modelTypes.contains(block.kind))
                    else {
                        throw AIReflowEvidence.invalid()
                    }
                } else if [.nonContent, .frontMatter].contains(block.kind), source.kind == .figure,
                    source.block.reflowMayExclude == true
                {
                    // Only explicitly eligible local crops may be treated as decorative metadata.
                } else if block.kind != source.kind {
                    throw AIReflowEvidence.invalid()
                }
                refs += source.objectIDs
            }
            guard Set(block.objectRefs).count == block.objectRefs.count, Set(block.objectRefs) == Set(refs) else {
                throw AIReflowEvidence.invalid()
            }
        }
    }

    private func delta(_ value: [String: Any]) async throws {
        guard let current, current.translates, try Self.integer(value, "block_index") == index,
            let parts = value["parts"] as? [[String: Any]], !parts.isEmpty, parts.count <= 16
        else { throw AIReflowEvidence.invalid() }
        var appended = ""
        for part in parts {
            switch part["type"] as? String {
            case "text":
                try Self.keys(part, ["type", "text"])
                guard let text = part["text"] as? String, !text.isEmpty, text.unicodeScalars.count <= 512,
                    !text.contains("[["),
                    !text.unicodeScalars.contains(where: {
                        $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
                    })
                else { throw AIReflowEvidence.invalid() }
                // Typed text stays literal. The draft and persisted HTML renderers escape
                // angle brackets, including tag-shaped text split across delta events.
                appended += text
            case "object_ref":
                try Self.keys(part, ["type", "object_id"])
                guard let id = part["object_id"] as? String, let marker = current.markers[id],
                    usedObjects.insert(id).inserted
                else {
                    throw AIReflowEvidence.invalid()
                }
                appended += marker
            default: throw AIReflowEvidence.invalid()
            }
        }
        guard translation.utf8.count + appended.utf8.count <= 64_000 else { throw AIReflowEvidence.invalid() }
        translation += appended
        try await onDraft(current.block, translation)
    }

    private static func keys(_ value: [String: Any], _ expected: Set<String>) throws {
        guard Set(value.keys) == expected else { throw AIReflowEvidence.invalid() }
    }
    private static func integer(_ value: [String: Any], _ key: String) throws -> Int {
        guard let raw = value[key] else { throw AIReflowEvidence.invalid() }
        let data = try JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed)
        return try decode(Int.self, from: data)
    }
    // Normalize only model parsing operations. A broad catch around consume/finish
    // would incorrectly relabel a decoding or Cocoa error thrown by a storage callback.
    private static func object(from data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data) } catch { throw AIReflowEvidence.invalid() }
    }
    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) } catch is DecodingError {
            throw AIReflowEvidence.invalid()
        }
    }
    private struct Header: Decodable {
        let v: Int
        let requestID: UUID
        let windowID: UUID
        let seq: Int
        enum CodingKeys: String, CodingKey {
            case v, seq
            case requestID = "request_id"
            case windowID = "window_id"
        }
    }
}
