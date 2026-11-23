import CoreFoundation
import Foundation

public enum AgentToolArguments: Sendable, Equatable {
    public struct Selection: Sendable, Equatable {
        public let id: UUID
        public let reason: String?
    }
    public struct Quotation: Sendable, Equatable {
        public let resultID: UUID
        public let quote: String
    }
    case createReadingNote(markdown: String, sources: [Quotation])
    case askUser(AgentClarification)
    case searchLibrary(String)
    case searchOnline(String, limit: Int? = nil)
    case presentResults(AgentPresentedResult.Purpose, [Selection])
    case readPaper(id: String, sourcePage: Int)
    case prepareImport(String)
    case openPaper(id: String, sourcePage: Int?)

    public static func parse(name: String, json: String, limits: AgentLimits) throws -> Self {
        guard json.utf8.count <= limits.maxArgumentBytes,
            let values = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { throw ReaderError.message("工具参数必须是长度受限的 JSON 对象。") }
        func keys(_ allowed: Set<String>, required: Set<String>) throws {
            guard Set(values.keys).isSubset(of: allowed), required.isSubset(of: Set(values.keys)) else {
                throw ReaderError.message("工具参数缺失或包含不支持的字段。")
            }
        }
        func string(_ key: String, max: Int) throws -> String {
            guard let value = values[key] as? String,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= max
            else { throw ReaderError.message("工具文字参数无效或过长。") }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func page() throws -> Int {
            guard let value = values["source_page"] as? NSNumber,
                CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                value.doubleValue >= 1, value.doubleValue <= 1_000_000,
                value.doubleValue.rounded() == value.doubleValue
            else { throw ReaderError.message("原文页码必须是一基正整数。") }
            return value.intValue
        }
        switch name {
        case "create_reading_note":
            try keys(["markdown", "sources"], required: ["markdown", "sources"])
            let markdown = try string("markdown", max: limits.maxArgumentBytes)
            guard let rows = values["sources"] as? [[String: Any]], (1...8).contains(rows.count) else {
                throw ReaderError.message("阅读笔记需要一至八处原文。")
            }
            let sources = try rows.map { row -> Quotation in
                guard Set(row.keys) == ["result_id", "quote"],
                    let raw = row["result_id"] as? String, let id = UUID(uuidString: raw),
                    let quote = row["quote"] as? String, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw ReaderError.message("请使用已登记的本地摘录和其中的原句。") }
                return Quotation(resultID: id, quote: quote)
            }
            return .createReadingNote(markdown: markdown, sources: sources)
        case "present_results":
            try keys(["purpose", "items"], required: ["purpose", "items"])
            guard let purpose = AgentPresentedResult.Purpose(rawValue: try string("purpose", max: 32)),
                [.recommendation, .citation, .match].contains(purpose),
                let rows = values["items"] as? [[String: Any]], !rows.isEmpty,
                rows.count <= min(limits.maxResults, 20)
            else { throw ReaderError.message("结果用途或展示项数无效。") }
            let items = try rows.map { row -> Selection in
                guard Set(row.keys).isSubset(of: ["result_id", "reason"]),
                    let raw = row["result_id"] as? String, let id = UUID(uuidString: raw)
                else { throw ReaderError.message("请选择工具已经返回的结果标识。") }
                if let value = row["reason"] {
                    guard let reason = value as? String, reason.count <= 200 else {
                        throw ReaderError.message("每项结果的理由应为不超过 200 字的短句。")
                    }
                    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                    return Selection(id: id, reason: trimmed.isEmpty ? nil : trimmed)
                }
                return Selection(id: id, reason: nil)
            }
            return .presentResults(purpose, items)
        case "search_library":
            try keys(["query"], required: ["query"])
            return .searchLibrary(try string("query", max: 512))
        case "search_online":
            try keys(["query", "limit"], required: ["query"])
            let query = try string("query", max: 512)
            guard let raw = values["limit"] else { return .searchOnline(query) }
            guard let count = raw as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(),
                count.doubleValue >= 1, count.doubleValue <= Double(min(limits.maxResults, 20)),
                count.doubleValue.rounded() == count.doubleValue
            else { throw ReaderError.message("检索数量须为正整数，当前上限为 \(max(0, min(limits.maxResults, 20)))。") }
            return .searchOnline(query, limit: count.intValue)
        case "read_paper":
            try keys(["paper_id", "source_page"], required: ["paper_id", "source_page"])
            return .readPaper(id: try string("paper_id", max: 128), sourcePage: try page())
        case "prepare_import":
            try keys(["candidate_id"], required: ["candidate_id"])
            return .prepareImport(try string("candidate_id", max: 128))
        case "open_paper":
            try keys(["paper_id", "source_page"], required: ["paper_id"])
            return .openPaper(
                id: try string("paper_id", max: 128), sourcePage: values["source_page"] == nil ? nil : try page())
        case "ask_user":
            try keys(["question", "options"], required: ["question", "options"])
            let question = try string("question", max: 512)
            guard let values = values["options"] as? [String], (2...4).contains(values.count) else {
                throw ReaderError.message("请提供二至四个可选回答。")
            }
            let options = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard options.allSatisfy({ !$0.isEmpty && $0.count <= 60 && !$0.contains(where: \.isNewline) }),
                Set(options.map { $0.lowercased() }).count == options.count
            else { throw ReaderError.message("选项应简短、互不重复。") }
            return .askUser(.init(question: question, options: options))
        default: throw ReaderError.message("不支持此工具；没有执行任何操作。")
        }
    }
}
