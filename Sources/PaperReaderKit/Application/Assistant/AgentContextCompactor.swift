import Foundation

/// Fits multi-turn tool transcripts into `maxContextBytes` by compacting older tool outputs
/// before dropping complete history turns or the latest tool group, always preserving
/// `(assistant.tool_calls, tool.tool_call_id)` pairing.
public enum AgentContextCompactor {
    public struct Fitted: Sendable {
        public let prior: [[AgentMessage]]
        public let current: [AgentMessage]
        public let finalReason: String?
        public let compacted: Bool
    }

    public static func fit(
        system: AgentMessage, prior: [[AgentMessage]], current: [AgentMessage], maxContextBytes: Int,
        reservedBytes: Int = 0
    ) throws -> Fitted {
        var prior = prior
        var current = current
        var compacted = false
        // Tool schemas travel with every request and count against the provider's context window.
        let budget = max(1, maxContextBytes - max(0, reservedBytes))

        func byteCount() throws -> Int {
            try JSONEncoder().encode([system] + prior.flatMap { $0 } + current).count
        }

        if try byteCount() <= budget {
            return Fitted(prior: prior, current: current, finalReason: nil, compacted: false)
        }

        // Phase 1: Compact older tool payloads inside `prior` turns (oldest first) before evicting turns.
        for turnIndex in prior.indices {
            var changed = false
            for messageIndex in prior[turnIndex].indices where prior[turnIndex][messageIndex].role == "tool" {
                if let raw = prior[turnIndex][messageIndex].content,
                    let slim = compactToolContent(raw), slim.utf8.count < raw.utf8.count
                {
                    prior[turnIndex][messageIndex].content = slim
                    changed = true
                }
            }
            if changed {
                compacted = true
                if try byteCount() <= budget {
                    return Fitted(prior: prior, current: current, finalReason: nil, compacted: true)
                }
            }
        }

        // Phase 2: Compact tool payloads in `current` strictly before the latest tool group.
        if let lastGroup = current.lastIndex(where: { $0.toolCalls?.isEmpty == false }) {
            for messageIndex in 0..<lastGroup where current[messageIndex].role == "tool" {
                if let raw = current[messageIndex].content,
                    let slim = compactToolContent(raw), slim.utf8.count < raw.utf8.count
                {
                    current[messageIndex].content = slim
                    compacted = true
                    if try byteCount() <= budget {
                        return Fitted(prior: prior, current: current, finalReason: nil, compacted: true)
                    }
                }
            }
        }

        // Phase 3: Drop oldest `prior` turns one by one.
        while !prior.isEmpty, try byteCount() > budget {
            prior.removeFirst()
        }
        if try byteCount() <= budget {
            return Fitted(prior: prior, current: current, finalReason: nil, compacted: compacted)
        }

        // Phase 4: Drop the latest incomplete/oversized tool group in `current` and switch to answer-only.
        if let lastGroup = current.lastIndex(where: { $0.toolCalls?.isEmpty == false }) {
            current.removeSubrange(lastGroup...)
            return Fitted(
                prior: prior, current: current,
                finalReason: "部分工具结果超过上下文容量，未纳入本次总结。",
                compacted: compacted)
        }

        throw ReaderError.message("上下文达到上限，请缩小范围或新建对话。")
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
            let slimRows: [[String: Any]] = results.prefix(6).map { row in
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
            summary["results"] = slimRows
            summary["total_results"] = results.count
        }
        guard let data = try? JSONSerialization.data(withJSONObject: summary) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
