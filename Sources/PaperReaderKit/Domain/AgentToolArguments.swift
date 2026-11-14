import CoreFoundation
import Foundation

public enum AgentToolArguments: Sendable, Equatable {
    case searchLibrary(String)
    case searchOnline(String)
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
        case "search_library", "search_online":
            try keys(["query"], required: ["query"])
            let query = try string("query", max: 512)
            return name == "search_library" ? .searchLibrary(query) : .searchOnline(query)
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
        default: throw ReaderError.message("不支持此工具；没有执行任何操作。")
        }
    }
}
