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

    init(
        evidence: AIReflowEvidence, requestID: UUID, windowID: UUID, configurationDigest: String,
        acceptedPlan: AIReflowPlan?, committed: Set<UUID>,
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
        guard ended, current == nil, let plan, index == plan.blocks.count else {
            throw ReaderError.message("AI 重排流尚未完整结束，可从已保存的段落继续。")
        }
    }

    private func event(_ line: String) async throws {
        guard !ended, line.utf8.count <= 65_536, sequence < 4096,
            let data = line.data(using: .utf8),
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = value["type"] as? String
        else { throw AIReflowEvidence.invalid() }
        let common: Set<String> = ["v", "request_id", "window_id", "seq", "type"]
        let extra: Set<String>
        switch type {
        case "window_plan": extra = ["blocks", "dispositions", "carry"]
        case "block_start", "block_end": extra = ["block_index"]
        case "translation_delta": extra = ["block_index", "parts"]
        case "window_end": extra = ["block_count"]
        default: throw AIReflowEvidence.invalid()
        }
        try Self.keys(value, common.union(extra))
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.v == 1, header.requestID == requestID, header.windowID == windowID,
            header.seq == sequence
        else { throw AIReflowEvidence.invalid() }
        sequence += 1
        try Task.checkCancellation()
        switch type {
        case "window_plan": try await receivePlan(value)
        case "block_start":
            guard let plan, current == nil, index < plan.blocks.count,
                try Self.integer(value, "block_index") == index
            else { throw AIReflowEvidence.invalid() }
            current = try evidence.assemble(plan.blocks[index])
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
            self.current = nil
            index += 1
        case "window_end":
            guard let plan, current == nil, index == plan.blocks.count,
                try Self.integer(value, "block_count") == plan.blocks.count
            else { throw AIReflowEvidence.invalid() }
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
                guard let rawID = segment["source_id"] as? String, let id = UUID(uuidString: rawID) else {
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
        guard blocks.flatMap(\.sourceIDs) == evidence.sources.map({ $0.block.id }) else {
            throw AIReflowEvidence.invalid()
        }
        var sourceIndex = 0
        for block in blocks {
            guard !block.sourceSegments.isEmpty else { throw AIReflowEvidence.invalid() }
            var refs: [String] = []
            for segment in block.sourceSegments {
                let source = evidence.sources[sourceIndex]
                guard segment.sourceID == source.block.id, segment.startUTF16 == 0,
                    segment.endUTF16 == source.block.text.utf16.count
                else { throw AIReflowEvidence.invalid() }
                if block.sourceSegments.count > 1 {
                    guard source.kind == .paragraph, source.translates, block.kind == .paragraph,
                        source.objects.allSatisfy({ $0.marker != nil })
                    else { throw AIReflowEvidence.invalid() }
                } else if source.kind == .paragraph {
                    guard [.paragraph, .title, .heading, .listItem, .substantiveFootnote].contains(block.kind) else {
                        throw AIReflowEvidence.invalid()
                    }
                } else if block.kind != source.kind {
                    throw AIReflowEvidence.invalid()
                }
                refs += source.objectIDs
                sourceIndex += 1
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
                guard let text = part["text"] as? String, !text.isEmpty, text.unicodeScalars.count <= 128,
                    !text.contains("[["), !text.contains("<"), !text.contains(">"),
                    !text.unicodeScalars.contains(where: {
                        $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
                    })
                else { throw AIReflowEvidence.invalid() }
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
        return try JSONDecoder().decode(Int.self, from: data)
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
