import CSQLite
import Foundation

public actor LibraryStore {
    public nonisolated let directory: URL
    private let databaseURL: URL

    public init(directory: URL) throws {
        self.directory = directory
        self.databaseURL = directory.appendingPathComponent("library.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.database(at: databaseURL) { db in
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &query, nil) == SQLITE_OK else {
                throw ReaderError.message("无法读取书库版本。")
            }
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { throw ReaderError.message("书库版本读取失败。") }
            let version = sqlite3_column_int(query, 0)
            sqlite3_finalize(query)
            query = nil
            guard version <= 1 else { throw ReaderError.message("书库来自更新版本，请升级应用。") }
            try Self.execute(db, "PRAGMA journal_mode=WAL")
            if version == 0 {
                try Self.execute(db, "BEGIN IMMEDIATE")
                do {
                    try Self.execute(
                        db,
                        "CREATE TABLE IF NOT EXISTS library (id INTEGER PRIMARY KEY CHECK (id=1), payload BLOB NOT NULL)"
                    )
                    try Self.execute(db, "PRAGMA user_version=1")
                    try Self.execute(db, "COMMIT")
                } catch {
                    try? Self.execute(db, "ROLLBACK")
                    throw error
                }
            }
        }
    }

    public func load() throws -> LibraryState {
        let data: Data? = try Self.database(at: databaseURL) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload FROM library WHERE id=1", -1, &statement, nil) == SQLITE_OK
            else {
                throw ReaderError.message("无法读取本地书库。")
            }
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else {
                throw ReaderError.message("本地书库读取失败，原文件已保留。")
            }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
        }
        guard let data else { return LibraryState() }
        let state = try JSONDecoder().decode(LibraryState.self, from: data)
        let header = try JSONDecoder().decode(SnapshotHeader.self, from: data)
        if header.version < LibraryState.currentVersion { try save(state) }
        return state
    }

    public func save(_ state: LibraryState, respectingCancellation: Bool = false) throws {
        if respectingCancellation { try Task.checkCancellation() }
        guard state.version == LibraryState.currentVersion else {
            throw ReaderError.message("不能写入不受支持的书库版本，原有资料已保留。")
        }
        try state.validateShelves()
        let data = try JSONEncoder().encode(state)
        try Self.database(at: databaseURL) { db in
            try Self.execute(db, "BEGIN IMMEDIATE")
            do {
                var statement: OpaquePointer?
                guard
                    sqlite3_prepare_v2(
                        db,
                        "INSERT INTO library(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                        -1, &statement, nil) == SQLITE_OK
                else {
                    throw ReaderError.message("无法准备书库写入。")
                }
                defer { sqlite3_finalize(statement) }
                let status = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement, 1, bytes.baseAddress, Int32(bytes.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                    throw ReaderError.message("保存失败，请检查剩余磁盘空间。")
                }
                if respectingCancellation { try Task.checkCancellation() }
                try Self.execute(db, "COMMIT")
            } catch {
                try? Self.execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    private struct SnapshotHeader: Decodable {
        let version: Int
    }

    private static func database<T>(at url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard
            sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK,
            let db = pointer
        else {
            if let pointer { sqlite3_close(pointer) }
            throw ReaderError.message("无法打开本地书库。")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        return try body(db)
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ReaderError.message("书库事务失败，原有内容未被替换。")
        }
    }
}
