import Foundation

/// Fits multi-turn tool transcripts into `maxContextBytes` by compacting older tool outputs and
/// historical reasoning before dropping complete history turns or the latest tool group. The
/// stable system prompt and tool definitions stay untouched so providers can reuse a prefix cache;
/// per-round budget state travels in a trailing ephemeral message.
public enum AgentContextCompactor {
    public struct Fitted: Sendable {
        public let prior: [[AgentMessage]]
        public let current: [AgentMessage]
        public let finalReason: String?
        public let compacted: Bool
        public let includedPersonalContext: Bool
    }

    public static func fit(
        system: AgentMessage, prior: [[AgentMessage]], current: [AgentMessage], maxContextBytes: Int,
        reservedBytes: Int = 0, personalContext: String = "", trailing: AgentMessage? = nil
    ) throws -> Fitted {
        var prior = prior
        var current = current
        var compacted = false
        var personalIncluded = !personalContext.isEmpty
        // Tool schemas travel with every request and count against the provider's context window.
        let budget = max(1, maxContextBytes - max(0, reservedBytes))

        func sizedCurrent() -> [AgentMessage] {
            guard personalIncluded else { return current }
            return applyingPersonalContext(personalContext, to: current)
        }

        func byteCount() throws -> Int {
            var messages = [system] + prior.flatMap { $0 } + sizedCurrent()
            if let trailing { messages.append(trailing) }
            return try JSONEncoder().encode(messages).count
        }

        if try byteCount() <= budget {
            return Fitted(
                prior: prior, current: current, finalReason: nil, compacted: false,
                includedPersonalContext: personalIncluded)
        }

        // Phase 1: Compact older tool payloads and reasoning inside `prior` turns (oldest first).
        for turnIndex in prior.indices {
            var changed = false
            for messageIndex in prior[turnIndex].indices {
                changed = compact(&prior[turnIndex][messageIndex]) || changed
            }
            if changed {
                compacted = true
                if try byteCount() <= budget {
                    return Fitted(
                        prior: prior, current: current, finalReason: nil, compacted: true,
                        includedPersonalContext: personalIncluded)
                }
            }
        }

        // Phase 2: Compact payloads in `current` strictly before the latest tool group.
        let lastGroup = current.lastIndex(where: { $0.toolCalls?.isEmpty == false })
        for messageIndex in current.indices where lastGroup.map({ messageIndex < $0 }) ?? true {
            if compact(&current[messageIndex]) {
                compacted = true
                if try byteCount() <= budget {
                    return Fitted(
                        prior: prior, current: current, finalReason: nil, compacted: true,
                        includedPersonalContext: personalIncluded)
                }
            }
        }

        // Phase 3: Drop oldest `prior` turns one by one. Personal context survives history.
        while !prior.isEmpty, try byteCount() > budget {
            prior.removeFirst()
        }
        if try byteCount() <= budget {
            return Fitted(
                prior: prior, current: current, finalReason: nil, compacted: compacted,
                includedPersonalContext: personalIncluded)
        }

        // Phase 4: Only when history is empty does an oversized request sacrifice personal
        // context. The caller can then still answer from the current evidence.
        if personalIncluded {
            personalIncluded = false
            if try byteCount() <= budget {
                return Fitted(
                    prior: prior, current: current, finalReason: nil, compacted: compacted,
                    includedPersonalContext: false)
            }
        }

        // Phase 5: Drop the latest incomplete/oversized tool group in `current` and switch to answer-only.
        if let lastGroup = current.lastIndex(where: { $0.toolCalls?.isEmpty == false }) {
            current.removeSubrange(lastGroup...)
            return Fitted(
                prior: prior, current: current,
                finalReason: "部分工具结果超过上下文容量，未纳入本次总结。",
                compacted: compacted, includedPersonalContext: false)
        }

        throw ReaderError.message("上下文达到上限，请缩小范围或新建对话。")
    }

    /// The exact prefix used both for sizing and for the request, so compaction and the eventual
    /// message list cannot disagree about the personal context bytes.
    public static func applyingPersonalContext(_ personalContext: String, to messages: [AgentMessage]) -> [AgentMessage]
    {
        guard !personalContext.isEmpty, let index = messages.lastIndex(where: { $0.role == "user" }) else {
            return messages
        }
        var result = messages
        result[index].content = personalContext + "\n本轮问题：\n" + (result[index].content ?? "")
        return result
    }

    @discardableResult
    private static func compact(_ message: inout AgentMessage) -> Bool {
        if message.role == "tool", let raw = message.content,
            let slim = compactToolContent(raw), slim.utf8.count < raw.utf8.count
        {
            message.content = slim
            return true
        }
        if message.role == "assistant", let raw = message.reasoningContent,
            let slim = compactReasoning(raw), slim.count < raw.count
        {
            message.reasoningContent = slim
            return true
        }
        return false
    }

    static func compactReasoning(_ raw: String) -> String? {
        guard raw.count > 600 else { return nil }
        return String(raw.prefix(240)) + "…（前序推理已压缩）"
    }

    static func compactToolContent(_ raw: String) -> String? {
        guard raw.utf8.count > 420 else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return nil
        }
        var summary: [String: Any] = ["ok": object["ok"] ?? true, "compacted": true]
        if let message = object["message"] as? String {
            summary["message"] = String(message.prefix(160))
        }
        if let truncated = object["truncated"] as? Bool {
            summary["truncated"] = truncated
        }
        if let results = object["results"] as? [[String: Any]] {
            summary["results"] = results.prefix(6).map(slimRecord)
            summary["total_results"] = results.count
        }
        if let overview = object["overview"] {
            summary["overview"] = slimJSONValue(overview, depth: 0)
        }
        if let topics = object["topics"] as? [[String: Any]] {
            summary["topics"] = topics.prefix(3).map(slimTopic)
            summary["total_topics"] = topics.count
        }
        if let memories = object["memories"] as? [[String: Any]] {
            summary["memories"] = memories.prefix(4).map { memory in
                [
                    "memory_id": memory["memory_id"] ?? "", "status": memory["status"] ?? "",
                    "origin": memory["origin"] ?? "",
                    "text": String((memory["text"] as? String ?? "").prefix(160)),
                ]
            }
            summary["total_memories"] = memories.count
        }
        if let connections = object["connections"] as? [[String: Any]] {
            summary["connections"] = connections.prefix(4).map { connection in
                [
                    "kind": connection["kind"] ?? "",
                    "summary": String((connection["summary"] as? String ?? "").prefix(120)),
                    "current": connection["current"] ?? "",
                    "members": (connection["members"] as? [Any])?.prefix(6).map { $0 } ?? [],
                ]
            }
            summary["total_connections"] = connections.count
        }
        if let sources = object["sources"] as? [[String: Any]] {
            summary["sources"] = sources.prefix(3).map { source in
                [
                    "paper_id": source["paper_id"] ?? "", "note_id": source["note_id"] ?? "",
                    "title": String((source["title"] as? String ?? "").prefix(120)),
                    "excerpt": String((source["excerpt"] as? String ?? "").prefix(80)),
                ]
            }
            summary["total_sources"] = sources.count
        }
        for (key, value) in object where summary[key] == nil {
            summary[key] = slimJSONValue(value, depth: 0)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.utf8.count < raw.utf8.count ? text : nil
    }

    private static func slimRecord(_ row: [String: Any]) -> [String: Any] {
        var item: [String: Any] = [:]
        for key in [
            "result_id", "paper_id", "candidate_id", "reading_note_id", "source_page", "import_status",
            "citation_id", "memory_id",
        ] {
            if let value = row[key] { item[key] = value }
        }
        if let title = row["title"] as? String { item["title"] = String(title.prefix(120)) }
        if let text = row["text"] as? String { item["text"] = String(text.prefix(140)) }
        return item
    }

    private static func slimTopic(_ topic: [String: Any]) -> [String: Any] {
        var item: [String: Any] = [:]
        for key in [
            "shelf", "papers", "papers_with_notes", "papers_with_discussions", "papers_read", "last_read_at",
        ] {
            if let value = topic[key] { item[key] = value }
        }
        if let sources = topic["sources"] as? [Any] {
            item["source_count"] = sources.count
            item["sources"] = sources.prefix(2).map { slimJSONValue($0, depth: 1) }
        }
        return item
    }

    private static func slimJSONValue(_ value: Any, depth: Int) -> Any {
        if let string = value as? String {
            return String(string.prefix(220))
        }
        if let number = value as? NSNumber {
            return number
        }
        if let array = value as? [Any] {
            let limit = depth == 0 ? 3 : 2
            var slimmed = array.prefix(limit).map { slimJSONValue($0, depth: depth + 1) }
            if array.count > limit { slimmed.append("…") }
            return slimmed
        }
        if let dictionary = value as? [String: Any] {
            guard depth < 3 else { return "…" }
            var result: [String: Any] = [:]
            for (key, nested) in dictionary.sorted(by: { $0.key < $1.key }).prefix(16) {
                result[key] = slimJSONValue(nested, depth: depth + 1)
            }
            return result
        }
        return String(describing: value).prefix(160)
    }
}
