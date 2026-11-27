import CSQLite
import Foundation

/// This database is disposable. Keys include the encoder revision, source ID and exact passage.
/// Multiple semantic indexes share one SQLite WAL file via distinct `namespace` keys.
///
/// Layout: a rowid table keeps each ~1.5 KB vector inline in its B-tree leaf (a `WITHOUT ROWID`
/// table spilled every vector into overflow pages, tripling file size and cold-load time), and new
/// files use 16 KiB pages so about ten vectors share one page. Loading copies BLOBs straight into
/// one contiguous matrix.
struct SemanticVectorCache {
    let url: URL
    let namespace: String

    init(url: URL, namespace: String = "default") {
        self.url = url
        self.namespace = namespace
    }

    func load(writer: String? = nil) throws -> SemanticVectorMatrix {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let namespaceData = Data(namespace.utf8)
        return try LibraryStore.database(at: url) { db in
            // Only takes effect while the file is still empty; existing caches keep their page size.
            try LibraryStore.execute(db, "PRAGMA page_size=16384")
            try LibraryStore.execute(db, "PRAGMA journal_mode=WAL")
            try LibraryStore.execute(db, "PRAGMA synchronous=NORMAL")
            try LibraryStore.execute(db, "PRAGMA busy_timeout=5000")
            try LibraryStore.execute(db, "PRAGMA cache_size=-32768")
            return try LibraryStore.transaction(db) {
                try Self.prepareSchema(db)
                if let writer {
                    try LibraryRecords.statement(db, "INSERT OR REPLACE INTO cache_writer_ns VALUES(?,?)") { stmt in
                        try LibraryRecords.bind(namespaceData, to: 1, in: stmt)
                        try LibraryRecords.bind(Data(writer.utf8), to: 2, in: stmt)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                    }
                }
                let expectedRows = try LibraryRecords.statement(
                    db, "SELECT count(*) FROM vectors_v2 WHERE namespace=?"
                ) { stmt -> Int in
                    try LibraryRecords.bind(namespaceData, to: 1, in: stmt)
                    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
                    return Int(sqlite3_column_int64(stmt, 0))
                }
                var matrix = SemanticVectorMatrix()
                guard expectedRows > 0 else { return matrix }
                let expectedBytes = try LibraryRecords.statement(
                    db, "SELECT length(vector) FROM vectors_v2 WHERE namespace=? LIMIT 1"
                ) { stmt -> Int in
                    try LibraryRecords.bind(namespaceData, to: 1, in: stmt)
                    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
                    return Int(sqlite3_column_int64(stmt, 0))
                }
                if expectedBytes > 0 {
                    matrix.reserveCapacity(rows: expectedRows, dimension: expectedBytes / MemoryLayout<Float>.size)
                }
                let totalRows = try LibraryRecords.statement(db, "SELECT count(*) FROM vectors_v2") { stmt -> Int in
                    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
                    return Int(sqlite3_column_int64(stmt, 0))
                }
                // Large namespaces are much faster with a linear table scan (+namespace suppresses the
                // fingerprint-ordered index, which otherwise causes random rowid lookups across pages).
                let selectSQL =
                    expectedRows * 4 >= totalRows
                    ? "SELECT fingerprint, vector FROM vectors_v2 WHERE +namespace=?"
                    : "SELECT fingerprint, vector FROM vectors_v2 WHERE namespace=?"
                return try LibraryRecords.statement(db, selectSQL) { stmt in
                    try LibraryRecords.bind(namespaceData, to: 1, in: stmt)
                    while true {
                        let status = sqlite3_step(stmt)
                        if status == SQLITE_DONE { return matrix }
                        guard status == SQLITE_ROW else { throw LibraryRecords.writeFailure }
                        let keyLength = Int(sqlite3_column_bytes(stmt, 0))
                        let vectorLength = Int(sqlite3_column_bytes(stmt, 1))
                        guard keyLength == 32, vectorLength > 0, vectorLength <= 16_384,
                            let keyBytes = sqlite3_column_blob(stmt, 0),
                            let vectorBytes = sqlite3_column_blob(stmt, 1)
                        else { continue }
                        matrix.insert(
                            Data(bytes: keyBytes, count: keyLength),
                            bytes: UnsafeRawBufferPointer(start: vectorBytes, count: vectorLength))
                    }
                }
            }
        }
    }

    func update(adding: [Data: [Float]], removing: Set<Data>, writer: String) throws {
        guard !adding.isEmpty || !removing.isEmpty else { return }
        let namespaceData = Data(namespace.utf8)
        try LibraryStore.database(at: url) { db in
            try LibraryStore.execute(db, "PRAGMA busy_timeout=5000")
            try LibraryStore.execute(db, "PRAGMA secure_delete=ON")
            try LibraryStore.transaction(db) {
                let ownsCache = try LibraryRecords.statement(
                    db, "SELECT 1 FROM cache_writer_ns WHERE namespace=? AND token=?"
                ) { stmt in
                    try LibraryRecords.bind(namespaceData, to: 1, in: stmt)
                    try LibraryRecords.bind(Data(writer.utf8), to: 2, in: stmt)
                    return sqlite3_step(stmt) == SQLITE_ROW
                }
                guard ownsCache else { return }
                try LibraryRecords.statement(db, "DELETE FROM vectors_v2 WHERE namespace=? AND fingerprint=?") { stmt in
                    for key in removing {
                        try LibraryRecords.bind(namespaceData, to: 1, in: stmt)
                        try LibraryRecords.bind(key, to: 2, in: stmt)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                        sqlite3_reset(stmt)
                    }
                }
                try LibraryRecords.statement(
                    db,
                    """
                    INSERT INTO vectors_v2(namespace, fingerprint, vector) VALUES(?,?,?)
                    ON CONFLICT(namespace, fingerprint) DO UPDATE SET vector=excluded.vector
                    """
                ) { stmt in
                    for (key, vector) in adding {
                        try LibraryRecords.bind(namespaceData, to: 1, in: stmt)
                        try LibraryRecords.bind(key, to: 2, in: stmt)
                        try LibraryRecords.bind(vector.withUnsafeBytes { Data($0) }, to: 3, in: stmt)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                        sqlite3_reset(stmt)
                    }
                }
            }
        }
    }

    /// Creates the rowid layout and moves vectors from the earlier `WITHOUT ROWID` table in place,
    /// so upgrading never re-encodes existing passages.
    private static func prepareSchema(_ db: OpaquePointer) throws {
        try LibraryStore.execute(
            db,
            """
            CREATE TABLE IF NOT EXISTS vectors_v2 (
                id INTEGER PRIMARY KEY, namespace BLOB NOT NULL, fingerprint BLOB NOT NULL, vector BLOB NOT NULL,
                UNIQUE (namespace, fingerprint))
            """)
        // A second scene or a reopened library supersedes in-flight cache writers per namespace.
        try LibraryStore.execute(
            db, "CREATE TABLE IF NOT EXISTS cache_writer_ns (namespace BLOB PRIMARY KEY, token BLOB NOT NULL)")
        let hasLegacy = try LibraryRecords.statement(
            db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='vectors_ns'"
        ) { sqlite3_step($0) == SQLITE_ROW }
        guard hasLegacy else { return }
        try LibraryStore.execute(
            db,
            """
            INSERT OR IGNORE INTO vectors_v2(namespace, fingerprint, vector)
            SELECT namespace, fingerprint, vector FROM vectors_ns ORDER BY namespace
            """)
        try LibraryStore.execute(db, "DROP TABLE vectors_ns")
    }
}
