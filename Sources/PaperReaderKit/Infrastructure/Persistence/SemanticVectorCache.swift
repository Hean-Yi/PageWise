import CSQLite
import Foundation

/// This database is disposable. Keys include the encoder revision, source ID and exact passage.
/// Multiple semantic indexes can share one unified SQLite WAL file via distinct `namespace` keys.
struct SemanticVectorCache {
    let url: URL
    let namespace: String

    init(url: URL, namespace: String = "default") {
        self.url = url
        self.namespace = namespace
    }

    func load(writer: String? = nil) throws -> [Data: [Float]] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let namespaceData = Data(namespace.utf8)
        return try LibraryStore.database(at: url) { db in
            try LibraryStore.execute(db, "PRAGMA journal_mode=WAL")
            try LibraryStore.execute(db, "PRAGMA synchronous=NORMAL")
            try LibraryStore.execute(db, "PRAGMA busy_timeout=5000")
            try LibraryStore.execute(
                db,
                "CREATE TABLE IF NOT EXISTS vectors_ns (namespace BLOB NOT NULL, fingerprint BLOB NOT NULL, vector BLOB NOT NULL, PRIMARY KEY (namespace, fingerprint)) WITHOUT ROWID"
            )
            // A second scene or a reopened library supersedes in-flight cache writers per namespace.
            try LibraryStore.execute(
                db, "CREATE TABLE IF NOT EXISTS cache_writer_ns (namespace BLOB PRIMARY KEY, token BLOB NOT NULL)")
            return try LibraryStore.transaction(db) {
                if let writer {
                    try LibraryRecords.statement(db, "INSERT OR REPLACE INTO cache_writer_ns VALUES(?,?)") { stmt in
                        try LibraryRecords.bind(namespaceData, to: 1, in: stmt)
                        try LibraryRecords.bind(Data(writer.utf8), to: 2, in: stmt)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                    }
                }
                return try LibraryRecords.statement(
                    db, "SELECT fingerprint, vector FROM vectors_ns WHERE namespace=?"
                ) { stmt in
                    try LibraryRecords.bind(namespaceData, to: 1, in: stmt)
                    var result: [Data: [Float]] = [:]
                    while true {
                        let status = sqlite3_step(stmt)
                        if status == SQLITE_DONE { return result }
                        guard status == SQLITE_ROW else { throw LibraryRecords.writeFailure }
                        let key = try LibraryRecords.blob(stmt, column: 0)
                        let bytes = try LibraryRecords.blob(stmt, column: 1)
                        guard key.count == 32, bytes.count > 0, bytes.count <= 16_384, bytes.count % 4 == 0 else {
                            continue
                        }
                        var values = [Float](repeating: 0, count: bytes.count / 4)
                        _ = values.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
                        if values.allSatisfy(\.isFinite) { result[key] = values }
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
                try LibraryRecords.statement(db, "DELETE FROM vectors_ns WHERE namespace=? AND fingerprint=?") { stmt in
                    for key in removing {
                        try LibraryRecords.bind(namespaceData, to: 1, in: stmt)
                        try LibraryRecords.bind(key, to: 2, in: stmt)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                        sqlite3_reset(stmt)
                    }
                }
                try LibraryRecords.statement(db, "INSERT OR REPLACE INTO vectors_ns VALUES(?,?,?)") { stmt in
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
}
