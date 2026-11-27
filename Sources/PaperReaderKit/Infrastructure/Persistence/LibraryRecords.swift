import CSQLite
import Foundation

/// A collection's order lives in a small, separate row. Prepending an imported paper never
/// rewrites the accumulated blocks, translations or notes of the papers that shift one slot.
struct LibraryRecords {
    let db: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(_ db: OpaquePointer) { self.db = db }

    func read(into state: inout LibraryState) throws {
        state.papers = try ordered("papers")
        state.readingNotes = try ordered("notes")
        state.highlights = try ordered("highlights")
        state.chats = try ordered("chats")
        state.memories = try ordered("memories")
        state.reading = try ordered("reading")
        state.bookmarks = try ordered("bookmarks")
        try enumerate("workspace") { key, data in
            state.workspace[key] = try decoder.decode(PaperWorkspace.self, from: data)
        }
    }

    @discardableResult func write(from old: LibraryState, to state: LibraryState) throws -> Bool {
        let titles = try sync("papers", old.papers, state.papers) { $0.title != $1.title }
        let notes = try sync("notes", old.readingNotes, state.readingNotes)
        try sync("highlights", old.highlights, state.highlights)
        let chats = try sync("chats", old.chats, state.chats)
        let memories = try sync("memories", old.memories, state.memories) { !$0.sameResearchContent(as: $1) }
        try sync("reading", old.reading, state.reading)
        try sync("bookmarks", old.bookmarks, state.bookmarks)
        if old.workspace != state.workspace {
            for (key, value) in state.workspace where old.workspace[key] != value {
                try put("workspace", key, encoder.encode(value))
            }
            for key in old.workspace.keys where state.workspace[key] == nil { try remove("workspace", key) }
        }
        return titles || notes || chats || memories
    }

    private func ordered<T: Decodable & Identifiable>(_ kind: String) throws -> [T] where T.ID == UUID {
        var order = [UUID]()
        var records = [UUID: T]()
        try enumerate(kind) { key, data in
            if key.isEmpty {
                order = try decoder.decode([UUID].self, from: data)
            } else {
                let value = try decoder.decode(T.self, from: data)
                guard value.id.uuidString == key else { throw Self.inconsistent }
                records[value.id] = value
            }
        }
        guard order.count == records.count else { throw Self.inconsistent }
        return try order.map { id in
            guard let value = records.removeValue(forKey: id) else { throw Self.inconsistent }
            return value
        }
    }

    @discardableResult private func sync<T: Encodable & Equatable & Identifiable>(
        _ kind: String, _ old: [T], _ new: [T], affectsResearch: (T, T) -> Bool = { _, _ in true }
    ) throws -> Bool where T.ID == UUID {
        // Swift Array equality immediately succeeds for the shared COW buffer of untouched collections.
        guard old != new else { return false }
        if old.count == new.count && zip(old, new).allSatisfy({ $0.id == $1.id }) {
            var changed = false
            for (prior, next) in zip(old, new) where prior != next {
                if affectsResearch(prior, next) { changed = true }
                try put(kind, next.id.uuidString, encoder.encode(next))
            }
            return changed
        }
        var remaining = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let ids = new.map(\.id)
        guard Set(ids).count == ids.count else { throw Self.inconsistent }
        for record in new where remaining.removeValue(forKey: record.id) != record {
            try put(kind, record.id.uuidString, encoder.encode(record))
        }
        for id in remaining.keys { try remove(kind, id.uuidString) }
        try put(kind, "", encoder.encode(ids))
        return true
    }

    private func enumerate(_ kind: String, row: (String, Data) throws -> Void) throws {
        try Self.statement(db, "SELECT record_key,payload FROM library_records WHERE kind=?") { statement in
            try Self.bind(kind, to: 1, in: statement)
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return }
                guard status == SQLITE_ROW, let key = sqlite3_column_text(statement, 0) else { throw Self.inconsistent }
                try row(String(cString: key), Self.blob(statement, column: 1))
            }
        }
    }

    private func put(_ kind: String, _ key: String, _ value: Data) throws {
        try Self.statement(db, "INSERT OR REPLACE INTO library_records(kind,record_key,payload) VALUES(?,?,?)") {
            stmt in
            try Self.bind(kind, to: 1, in: stmt)
            try Self.bind(key, to: 2, in: stmt)
            try Self.bind(value, to: 3, in: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw Self.writeFailure }
        }
    }

    private func remove(_ kind: String, _ key: String) throws {
        try Self.statement(db, "DELETE FROM library_records WHERE kind=? AND record_key=?") { stmt in
            try Self.bind(kind, to: 1, in: stmt)
            try Self.bind(key, to: 2, in: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw Self.writeFailure }
        }
    }

    static func statement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw writeFailure }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    static func blob(_ stmt: OpaquePointer, column: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(stmt, column) else { throw inconsistent }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }

    private static func bind(_ text: String, to column: Int32, in stmt: OpaquePointer) throws {
        guard sqlite3_bind_text(stmt, column, text, -1, transient) == SQLITE_OK else { throw writeFailure }
    }

    static func bind(_ data: Data, to column: Int32, in stmt: OpaquePointer) throws {
        let status = data.withUnsafeBytes {
            sqlite3_bind_blob64(stmt, column, $0.baseAddress, UInt64($0.count), transient)
        }
        guard status == SQLITE_OK else { throw writeFailure }
    }

    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    private static var inconsistent: ReaderError { .message("书库记录或顺序无效，原资料已保留。") }
    static var writeFailure: ReaderError { .message("无法完成书库事务，请检查磁盘空间和读写权限。") }
}
