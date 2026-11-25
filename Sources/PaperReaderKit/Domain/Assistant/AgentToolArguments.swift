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
    public struct NoteCitation: Sendable, Equatable {
        public var passage: Quotation
        public var label: String
    }
    case library(AgentLibraryOperation)
    case createReadingNote(
        markdown: String, sources: [Quotation], citations: [NoteCitation], dimension: CloseReadingDimension?)
    case closeReadPaper(String)
    case askUser(AgentClarification)
    case researchOverview(query: String?)
    case proposeResearchQuestion(question: String, noteResult: UUID?, quote: String)
    case searchLibrary(String)
    case searchReadingNotes(String)
    case searchOnline(String, limit: Int? = nil, scope: PaperSearchScope = .all)
    case recommendRelated(limit: Int?)
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
        func searchLimit() throws -> Int? {
            guard let raw = values["limit"] else { return nil }
            guard let count = raw as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(),
                count.doubleValue >= 1, count.doubleValue <= Double(min(limits.maxResults, 20)),
                count.doubleValue.rounded() == count.doubleValue
            else { throw ReaderError.message("检索数量须为正整数，当前上限为 \(max(0, min(limits.maxResults, 20)))。") }
            return count.intValue
        }
        func uuid(_ key: String) throws -> UUID {
            guard let id = UUID(uuidString: try string(key, max: 36)) else { throw ReaderError.message("需要已登记的书库 ID。") }
            return id
        }
        switch name {
        case "research_overview":
            try keys(["query"], required: [])
            return .researchOverview(query: values["query"] == nil ? nil : try string("query", max: 500))
        case "propose_research_question":
            try keys(["question", "note_result_id", "quote"], required: ["question", "quote"])
            return .proposeResearchQuestion(
                question: try string("question", max: 800),
                noteResult: values["note_result_id"] == nil ? nil : try uuid("note_result_id"),
                quote: try string("quote", max: 960))
        case "list_library":
            try keys(["scope", "shelf_id", "offset"], required: ["scope"])
            guard let scope = AgentLibraryScope(rawValue: try string("scope", max: 16)),
                (scope == .shelf) == (values["shelf_id"] != nil)
            else { throw ReaderError.message("按单个书架查看时须给出其 ID。") }
            var offset = 0
            if let raw = values["offset"] {
                guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                    (0...1_000_000).contains(n.doubleValue), n.doubleValue.rounded() == n.doubleValue
                else { throw ReaderError.message("书库列表起点无效。") }
                offset = n.intValue
            }
            return .library(.list(scope, shelf: scope == .shelf ? try uuid("shelf_id") : nil, offset: offset))
        case "prepare_local_import":
            try keys(["destination"], required: ["destination"])
            let target = try string("destination", max: 36)
            return .library(.prepareLocalImport(target == "unfiled" ? nil : try uuid("destination")))
        case "create_shelf":
            try keys(["name"], required: ["name"])
            return .library(.createShelf(try string("name", max: 240)))
        case "rename_shelf":
            try keys(["shelf_id", "name"], required: ["shelf_id", "name"])
            return .library(.renameShelf(try uuid("shelf_id"), try string("name", max: 240)))
        case "move_papers":
            try keys(["paper_ids", "destination"], required: ["paper_ids", "destination"])
            guard let raw = values["paper_ids"] as? [String], (1...50).contains(raw.count) else {
                throw ReaderError.message("每次可移动一至五十篇已登记的论文。")
            }
            let ids = raw.compactMap(UUID.init(uuidString:))
            guard Set(ids).count == raw.count else { throw ReaderError.message("论文 ID 无效或重复。") }
            let target = try string("destination", max: 36)
            return .library(.movePapers(ids, to: target == "unfiled" ? nil : try uuid("destination")))
        case "prepare_delete_shelf":
            try keys(["shelf_id"], required: ["shelf_id"])
            return .library(.prepareDeleteShelf(try uuid("shelf_id")))
        case "prepare_delete_paper":
            try keys(["paper_id"], required: ["paper_id"])
            return .library(.prepareDeletePaper(try uuid("paper_id")))
        case "close_read_paper":
            try keys(["paper_id"], required: ["paper_id"])
            return .closeReadPaper(try string("paper_id", max: 128))
        case "create_reading_note":
            try keys(["markdown", "sources", "citations", "dimension"], required: ["markdown", "sources"])
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
            var citations: [NoteCitation] = []
            if let value = values["citations"] {
                guard let rows = value as? [[String: Any]], rows.count <= 8 else {
                    throw ReaderError.message("每条笔记最多引用八处书库笔记。")
                }
                citations = try rows.map { row in
                    guard Set(row.keys) == ["result_id", "quote", "label"],
                        let raw = row["result_id"] as? String, let id = UUID(uuidString: raw),
                        let quote = row["quote"] as? String,
                        !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        let label = row["label"] as? String, (1...120).contains(label.count)
                    else { throw ReaderError.message("引用需要已检索的笔记、其中的原句和链接文字。") }
                    return .init(passage: .init(resultID: id, quote: quote), label: label)
                }
            }
            var dimension: CloseReadingDimension?
            if values["dimension"] != nil {
                guard let parsed = CloseReadingDimension(rawValue: try string("dimension", max: 32))
                else { throw ReaderError.message("未知的精读分析维度。") }
                dimension = parsed
            }
            return .createReadingNote(markdown: markdown, sources: sources, citations: citations, dimension: dimension)
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
        case "search_reading_notes":
            try keys(["query"], required: ["query"])
            return .searchReadingNotes(try string("query", max: 512))
        case "search_library":
            try keys(["query"], required: ["query"])
            return .searchLibrary(try string("query", max: 512))
        case "search_online":
            try keys(["query", "limit", "source"], required: ["query"])
            let raw = values["source"] == nil ? "all" : try string("source", max: 24)
            guard let scope = PaperSearchScope(rawValue: raw) else { throw ReaderError.message("检索来源无效。") }
            return .searchOnline(try string("query", max: 512), limit: try searchLimit(), scope: scope)
        case "recommend_related":
            try keys(["limit"], required: [])
            return .recommendRelated(limit: try searchLimit())
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
