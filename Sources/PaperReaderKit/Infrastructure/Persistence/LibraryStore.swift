import CSQLite
import Foundation

public actor LibraryStore {
    public nonisolated let directory: URL
    private let databaseURL: URL
    private var baseline: (state: LibraryState, revision: Int64)?

    public init(directory: URL) throws {
        self.directory = directory
        databaseURL = directory.appendingPathComponent("library.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.database(at: databaseURL) { db in
            let version = try Self.integer(db, "PRAGMA user_version")
            guard (0...2).contains(version) else { throw ReaderError.message("书库来自更新版本，请升级应用。") }
            try Self.execute(db, "PRAGMA journal_mode=WAL")
            if version == 0 {
                try Self.transaction(db) {
                    guard try Self.integer(db, "PRAGMA user_version") == 0 else { return }
                    try Self.execute(
                        db,
                        "CREATE TABLE IF NOT EXISTS library (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)"
                    )
                    try Self.execute(db, "PRAGMA user_version=1")
                }
            }
        }
    }

    public func load() throws -> LibraryState {
        baseline = nil
        let loaded = try Self.database(at: databaseURL) { db in
            try Self.transaction(db) { () -> (state: LibraryState, revision: Int64) in
                if try Self.integer(db, "PRAGMA user_version") == 1 {
                    try Self.execute(
                        db,
                        """
                        CREATE TABLE IF NOT EXISTS library_records (
                            kind TEXT NOT NULL, record_key TEXT NOT NULL, payload BLOB NOT NULL,
                            PRIMARY KEY(kind,record_key)
                        ) WITHOUT ROWID
                        """)
                    try Self.execute(
                        db,
                        "CREATE TABLE IF NOT EXISTS library_generation (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL)"
                    )
                    try Self.execute(db, "INSERT OR IGNORE INTO library_generation VALUES(1,0)")
                    try Self.execute(db, "PRAGMA user_version=2")
                }
                let data: Data? = try LibraryRecords.statement(db, "SELECT payload FROM library WHERE id=1") { stmt in
                    let result = sqlite3_step(stmt)
                    if result == SQLITE_DONE { return nil }
                    guard result == SQLITE_ROW else { throw LibraryRecords.writeFailure }
                    return try LibraryRecords.blob(stmt, column: 0)
                }
                var revision = try Self.integer(db, "SELECT revision FROM library_generation WHERE id=1")
                guard let data else {
                    guard revision == 0 else { throw ReaderError.message("书库目录信息缺失，原资料已保留。") }
                    return (LibraryState(), revision)
                }
                let decoder = JSONDecoder()
                let header = try decoder.decode(Header.self, from: data)
                let rows = LibraryRecords(db)
                let state: LibraryState
                if header.recordFormat == nil {
                    // The payload remains authoritative until every migrated row and its order commit together.
                    state = try decoder.decode(LibraryState.self, from: data)
                    try Self.execute(db, "DELETE FROM library_records")
                    try rows.write(from: LibraryState(), to: state)
                    try Self.writeCatalog(Catalog(state), db: db)
                    try Self.execute(db, "UPDATE library_generation SET revision=revision+1 WHERE id=1")
                    revision += 1
                } else {
                    guard header.recordFormat == 2, header.version == LibraryState.currentVersion else {
                        throw ReaderError.message("书库版本不受支持，原资料已保留。")
                    }
                    var restored = try decoder.decode(Catalog.self, from: data).state
                    try rows.read(into: &restored)
                    try restored.validateOrdering()
                    try restored.validateShelves()
                    state = restored
                }
                return (state, revision)
            }
        }
        baseline = loaded
        return loaded.state
    }

    public func save(_ state: LibraryState, respectingCancellation: Bool = false, deleting paper: Paper? = nil) throws {
        if respectingCancellation { try Task.checkCancellation() }
        guard state.version == LibraryState.currentVersion else {
            throw ReaderError.message("不能写入不受支持的书库版本，原有资料已保留。")
        }
        if baseline == nil { _ = try load() }
        guard let previous = baseline else { throw LibraryRecords.writeFailure }
        let catalog = Catalog(state)
        let catalogChanged = catalog != Catalog(previous.state) || previous.revision == 0
        if catalogChanged || previous.state.papers != state.papers {
            try state.validateShelves()
            try state.validateOrdering()
        }
        let revision = try Self.database(at: databaseURL) { db in
            try Self.transaction(db) {
                guard try Self.integer(db, "SELECT revision FROM library_generation WHERE id=1") == previous.revision
                else { throw ReaderError.message("书库已由另一个实例更新，请重新打开书库后保存。") }
                if let paper {
                    guard !state.papers.contains(where: { $0.id == paper.id }) else {
                        throw ReaderError.message("论文仍在书库中。")
                    }
                    try stageFileRemoval(paper)
                }
                let start = sqlite3_total_changes64(db)
                try LibraryRecords(db).write(from: previous.state, to: state)
                if catalogChanged { try Self.writeCatalog(catalog, db: db) }
                if respectingCancellation { try Task.checkCancellation() }
                guard sqlite3_total_changes64(db) > start else { return previous.revision }
                try Self.execute(db, "UPDATE library_generation SET revision=revision+1 WHERE id=1")
                return previous.revision + 1
            }
        }
        baseline = (state, revision)
    }

    public func compact() throws {
        try Self.database(at: databaseURL) { db in
            try Self.execute(db, "VACUUM")
            try Self.execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    private struct Header: Decodable {
        let version: Int
        let recordFormat: Int?
    }

    /// Only collection-level settings are serialized together. The domain Codable format remains
    /// readable for old snapshots. New persistent fields must belong here or in LibraryRecords.
    private struct Catalog: Codable, Equatable {
        let recordFormat: Int
        let version: Int
        let shelves: [Shelf]
        let paperShelfIDs: [String: UUID]
        let manualPaperIDs: [UUID]
        let preferredSort: LibrarySort

        init(_ state: LibraryState) {
            recordFormat = 2
            version = state.version
            shelves = state.shelves
            paperShelfIDs = state.paperShelfIDs
            manualPaperIDs = state.manualPaperIDs
            preferredSort = state.preferredSort
        }

        var state: LibraryState {
            var state = LibraryState()
            state.shelves = shelves
            state.paperShelfIDs = paperShelfIDs
            state.manualPaperIDs = manualPaperIDs
            state.preferredSort = preferredSort
            return state
        }
    }

    private static func writeCatalog(_ catalog: Catalog, db: OpaquePointer) throws {
        try LibraryRecords.statement(db, "INSERT OR REPLACE INTO library(id,payload) VALUES(1,?)") { stmt in
            try LibraryRecords.bind(JSONEncoder().encode(catalog), to: 1, in: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
        }
    }

    private static func integer(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        try LibraryRecords.statement(db, sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw LibraryRecords.writeFailure }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    private static func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute(db, "COMMIT")
            return value
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
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
