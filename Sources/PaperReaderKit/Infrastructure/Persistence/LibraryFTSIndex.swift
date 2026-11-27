import CSQLite
import Foundation

/// Rebuildable in-memory SQLite FTS5 index providing BM25 passage ranking for local paper search.
final class LibraryFTSIndex {
    struct Hit: Sendable {
        let paperID: UUID
        let blockID: UUID?
        let sourcePage: Int?
        let title: String
        let excerpt: String
        let score: Int
    }

    private var db: OpaquePointer?
    private var hasTrigram = false

    init() {
        var handle: OpaquePointer?
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return
        }
        let ddl = """
            CREATE VIRTUAL TABLE paper_fts USING fts5(
                paper_id UNINDEXED,
                block_id UNINDEXED,
                source_page UNINDEXED,
                title,
                body,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """
        guard sqlite3_exec(handle, ddl, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return
        }
        let trigramDDL = """
            CREATE VIRTUAL TABLE paper_fts_trigram USING fts5(
                paper_id UNINDEXED,
                block_id UNINDEXED,
                source_page UNINDEXED,
                title,
                body,
                tokenize = 'trigram'
            );
            """
        hasTrigram = sqlite3_exec(handle, trigramDDL, nil, nil, nil) == SQLITE_OK
        db = handle
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    var isAvailable: Bool { db != nil }

    func remove(paperID: UUID) {
        guard let db else { return }
        deleteRows(paperID: paperID, table: "paper_fts", in: db)
        if hasTrigram { deleteRows(paperID: paperID, table: "paper_fts_trigram", in: db) }
    }

    private func deleteRows(paperID: UUID, table: String, in db: OpaquePointer) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE paper_id = ?", -1, &stmt, nil) == SQLITE_OK,
            let stmt
        else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(paperID.uuidString, at: 1, in: stmt)
        _ = sqlite3_step(stmt)
    }

    func replace(
        paperID: UUID, title: String, passages: [(blockID: UUID?, sourcePage: Int?, text: String)]
    ) {
        guard let db else { return }
        _ = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        remove(paperID: paperID)
        let rows =
            passages.isEmpty
            ? [(blockID: UUID?.none, sourcePage: Int?.none, text: "")]
            : passages
        guard insertRows(paperID: paperID, title: title, rows: rows, table: "paper_fts", in: db) else {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        if hasTrigram {
            _ = insertRows(paperID: paperID, title: title, rows: rows, table: "paper_fts_trigram", in: db)
        }
        _ = sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private func insertRows(
        paperID: UUID, title: String, rows: [(blockID: UUID?, sourcePage: Int?, text: String)],
        table: String, in db: OpaquePointer
    ) -> Bool {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO \(table)(paper_id, block_id, source_page, title, body) VALUES (?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(paperID.uuidString, at: 1, in: stmt)
            if let blockID = row.blockID {
                bindText(blockID.uuidString, at: 2, in: stmt)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let page = row.sourcePage {
                sqlite3_bind_int(stmt, 3, Int32(page))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            bindText(title, at: 4, in: stmt)
            bindText(row.text, at: 5, in: stmt)
            _ = sqlite3_step(stmt)
        }
        return true
    }

    func search(terms: Set<String>, requireAllTerms: Bool = true, limit: Int) -> [Hit] {
        guard let db, limit > 0 else { return [] }
        let sanitized = terms.compactMap { raw -> String? in
            let clean = raw.filter { $0.isLetter || $0.isNumber }
            guard !clean.isEmpty else { return nil }
            return "\"\(clean)\"*"
        }.sorted()
        guard !sanitized.isEmpty else { return [] }
        let matchQuery = sanitized.joined(separator: requireAllTerms ? " AND " : " OR ")
        return runQuery(table: "paper_fts", matchQuery: matchQuery, limit: limit, in: db)
    }

    /// Trigram BM25 lookup for >=3-character CJK or substring terms so mixed Chinese/English
    /// queries do not bypass SQLite FTS5 indexing.
    func searchTrigram(terms: Set<String>, requireAllTerms: Bool = false, limit: Int) -> [Hit] {
        guard let db, hasTrigram, limit > 0 else { return [] }
        let sanitized = terms.compactMap { raw -> String? in
            let clean = raw.filter { $0.isLetter || $0.isNumber }
            guard clean.count >= 3 else { return nil }
            return "\"\(clean)\""
        }.sorted()
        guard !sanitized.isEmpty else { return [] }
        let matchQuery = sanitized.joined(separator: requireAllTerms ? " AND " : " OR ")
        return runQuery(table: "paper_fts_trigram", matchQuery: matchQuery, limit: limit, in: db)
    }

    private func runQuery(table: String, matchQuery: String, limit: Int, in db: OpaquePointer) -> [Hit] {
        let sql = """
            SELECT paper_id, block_id, source_page, title, body, bm25(\(table), 0.0, 0.0, 0.0, 5.0, 1.0) AS rank
            FROM \(table)
            WHERE \(table) MATCH ?
            ORDER BY rank ASC, paper_id ASC, rowid ASC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(matchQuery, at: 1, in: stmt)
        sqlite3_bind_int(stmt, 2, Int32(min(max(limit * 8, 32), 512)))

        var seenPapers = Set<UUID>()
        var hits: [Hit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawPaper = columnText(stmt, index: 0), let paperID = UUID(uuidString: rawPaper),
                seenPapers.insert(paperID).inserted
            else { continue }
            let blockID = columnText(stmt, index: 1).flatMap(UUID.init(uuidString:))
            let sourcePage = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 2)) + 1
            let title = columnText(stmt, index: 3) ?? ""
            let body = columnText(stmt, index: 4) ?? ""
            let bm25Score = sqlite3_column_double(stmt, 5)
            // FTS5 bm25() returns negative scores where more negative indicates a stronger match.
            let normalizedScore = max(1, Int(((-bm25Score) * 100).rounded()))
            hits.append(
                Hit(
                    paperID: paperID, blockID: blockID, sourcePage: sourcePage, title: title,
                    excerpt: String(body.prefix(1_400)), score: normalizedScore))
            if hits.count >= limit { break }
        }
        return hits
    }

    private func bindText(_ value: String, at index: Int32, in stmt: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        value.withCString { pointer in
            _ = sqlite3_bind_text(stmt, index, pointer, -1, transient)
        }
    }

    private func columnText(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }
}
