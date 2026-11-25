import CSQLite
import Foundation

/// This database is disposable. Keys include the encoder revision, source ID and exact passage.
struct SemanticVectorCache {
    let url: URL

    func load(writer: String? = nil) throws -> [Data: [Float]] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try LibraryStore.database(at: url) { db in
            try LibraryStore.execute(
                db,
                "CREATE TABLE IF NOT EXISTS vectors (fingerprint BLOB PRIMARY KEY, vector BLOB NOT NULL) WITHOUT ROWID")
            // A second scene or a reopened library supersedes in-flight cache writers from the old session.
            try LibraryStore.execute(
                db, "CREATE TABLE IF NOT EXISTS cache_writer (slot INTEGER PRIMARY KEY, token BLOB NOT NULL)")
            return try LibraryStore.transaction(db) {
                if let writer {
                    try LibraryRecords.statement(db, "INSERT OR REPLACE INTO cache_writer VALUES(1,?)") { stmt in
                        try LibraryRecords.bind(Data(writer.utf8), to: 1, in: stmt)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                    }
                }
                return try LibraryRecords.statement(db, "SELECT fingerprint, vector FROM vectors") { stmt in
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
        try LibraryStore.database(at: url) { db in
            try LibraryStore.execute(db, "PRAGMA secure_delete=ON")
            try LibraryStore.transaction(db) {
                let ownsCache = try LibraryRecords.statement(db, "SELECT 1 FROM cache_writer WHERE slot=1 AND token=?")
                { stmt in
                    try LibraryRecords.bind(Data(writer.utf8), to: 1, in: stmt)
                    return sqlite3_step(stmt) == SQLITE_ROW
                }
                guard ownsCache else { return }
                try LibraryRecords.statement(db, "DELETE FROM vectors WHERE fingerprint=?") { stmt in
                    for key in removing {
                        try LibraryRecords.bind(key, to: 1, in: stmt)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                        sqlite3_reset(stmt)
                    }
                }
                try LibraryRecords.statement(db, "INSERT OR REPLACE INTO vectors VALUES(?,?)") { stmt in
                    for (key, vector) in adding {
                        try LibraryRecords.bind(key, to: 1, in: stmt)
                        try LibraryRecords.bind(vector.withUnsafeBytes { Data($0) }, to: 2, in: stmt)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                        sqlite3_reset(stmt)
                    }
                }
            }
        }
    }
}
