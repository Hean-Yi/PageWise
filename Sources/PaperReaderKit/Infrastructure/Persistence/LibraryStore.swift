import CSQLite
import CryptoKit
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
            guard (0...3).contains(version) else { throw ReaderError.message("书库来自更新版本，请升级应用。") }
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
                if try Self.integer(db, "PRAGMA user_version") == 2 {
                    try Self.ensureResearchSchema(db)
                    try Self.execute(db, "PRAGMA user_version=3")
                }
                if try Self.integer(db, "PRAGMA user_version") >= 3 {
                    // Keep the append-only log and its checkpoints explicit even if an interrupted
                    // migration left only part of the table set behind.
                    try Self.ensureResearchSchema(db)
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
                    guard header.recordFormat == 2,
                        (13...LibraryState.currentVersion).contains(header.version)
                    else {
                        throw ReaderError.message("书库版本不受支持，原资料已保留。")
                    }
                    var restored = try decoder.decode(Catalog.self, from: data).state
                    try rows.read(into: &restored)
                    try restored.validateOrdering()
                    try restored.validateShelves()
                    try restored.validateMemorySuppression()
                    if header.version < LibraryState.currentVersion {
                        // v14 adds suppression and v15 adds optional preference attribution. Existing rows keep their IDs.
                        try Self.writeCatalog(Catalog(restored), db: db)
                        try Self.execute(db, "UPDATE library_generation SET revision=revision+1 WHERE id=1")
                        revision += 1
                    }
                    state = restored
                }
                return (state, revision)
            }
        }
        baseline = loaded
        return loaded.state
    }

    public struct Changes: Sendable { public let researchSourcesChanged: Bool }

    @discardableResult public func save(
        _ state: LibraryState, respectingCancellation: Bool = false, deleting paper: Paper? = nil
    ) throws -> Changes {
        if respectingCancellation { try Task.checkCancellation() }
        guard state.version == LibraryState.currentVersion else {
            throw ReaderError.message("不能写入不受支持的书库版本，原有资料已保留。")
        }
        if baseline == nil { _ = try load() }
        guard let previous = baseline else { throw LibraryRecords.writeFailure }
        let catalog = Catalog(state)
        let catalogChanged = catalog != Catalog(previous.state) || previous.revision == 0
        if state.suppressedMemoryFingerprints != previous.state.suppressedMemoryFingerprints {
            try state.validateMemorySuppression()
        }
        if catalogChanged || previous.state.papers != state.papers {
            try state.validateShelves()
            try state.validateOrdering()
        }
        let (revision, sourcesChanged) = try Self.database(at: databaseURL) { db in
            try Self.transaction(db) {
                guard try Self.integer(db, "SELECT revision FROM library_generation WHERE id=1") == previous.revision
                else { throw ReaderError.message("书库已由另一个实例更新，请重新打开书库后保存。") }
                if let paper {
                    guard !state.papers.contains(where: { $0.id == paper.id }) else {
                        throw ReaderError.message("论文仍在书库中。")
                    }
                    try stageFileRemoval(paper)
                    if try Self.hasResearchCheckpoint(db, .brief) { try Self.execute(db, "DELETE FROM research_brief") }
                }
                let start = sqlite3_total_changes64(db)
                let recordsChanged = try LibraryRecords(db).write(from: previous.state, to: state)
                if recordsChanged, !previous.state.memories.isEmpty,
                    Self.mayRevokeMemory(from: previous.state, to: state),
                    let data = try Self.checkpoint(db, .sleep)
                {
                    let eligible = MemorySleepEdition.eligible(state)
                    if var edition = try? JSONDecoder().decode(MemorySleepEdition.self, from: data) {
                        let previousEdition = edition
                        try edition.reconcile(eligible)
                        if edition != previousEdition {
                            try Self.writeCheckpoint(try JSONEncoder().encode(edition), db, .sleep)
                        }
                    } else {
                        try Self.execute(db, "DELETE FROM memory_sleep")
                    }
                }
                if catalogChanged { try Self.writeCatalog(catalog, db: db) }
                if respectingCancellation { try Task.checkCancellation() }
                guard sqlite3_total_changes64(db) > start else { return (previous.revision, false) }
                try Self.execute(db, "UPDATE library_generation SET revision=revision+1 WHERE id=1")
                let shelfChanged =
                    state.shelves != previous.state.shelves || state.paperShelfIDs != previous.state.paperShelfIDs
                let sourcesChanged = recordsChanged || shelfChanged
                if sourcesChanged {
                    // The generation advances even when every event key was already seen. This is
                    // what lets a record return to an earlier wording without leaving the derived
                    // index stuck at the wording it had in between.
                    try Self.execute(db, "UPDATE research_generation SET revision=revision+1 WHERE id=1")
                    let events = ResearchEventBuilder.events(
                        from: previous.state, to: state, occurredAt: Date())
                    try Self.appendResearchEvents(events, libraryRevision: previous.revision + 1, db: db)
                }
                return (previous.revision + 1, sourcesChanged)
            }
        }
        baseline = (state, revision)
        return Changes(researchSourcesChanged: sourcesChanged)
    }

    /// Appending papers, ordinary discussion turns and new memories cannot withdraw a source.
    /// Avoid decoding and hashing the sleep edition on those frequent foreground writes.
    private static func mayRevokeMemory(from old: LibraryState, to next: LibraryState) -> Bool {
        if old.papers.count > next.papers.count || old.chats.count > next.chats.count { return true }
        if old.memories != next.memories {
            if next.memories.count < old.memories.count { return true }
            let prefixUnchanged = zip(old.memories, next.memories).allSatisfy { $0.sameResearchContent(as: $1) }
            if !prefixUnchanged { return true }
        }
        if old.readingNotes != next.readingNotes && !next.readingNotes.starts(with: old.readingNotes) { return true }
        if old.papers != next.papers {
            let retained = Set(next.papers.map(\.id))
            if old.papers.contains(where: { !retained.contains($0.id) }) { return true }
        }
        if old.chats != next.chats {
            // A generated report can disqualify a previously reader-owned note from memory.
            guard next.chats.starts(with: old.chats) else { return true }
            return next.chats.dropFirst(old.chats.count).contains {
                $0.readingNoteID != nil || $0.closeReadingNoteIDs != nil
            }
        }
        return false
    }

    /// Hold the writer lock while deciding which files have committed references. A second
    /// instance may have finished an import between this instance's load and startup recovery.
    public func recoverManagedFiles() throws {
        guard let previous = baseline else { throw ReaderError.message("请先读取书库再清理文件。") }
        try Self.database(at: databaseURL) { db in
            try Self.transaction(db) {
                guard try Self.integer(db, "SELECT revision FROM library_generation WHERE id=1") == previous.revision
                else { return }
                try recoverFileRemovals(keeping: previous.state.papers)
                try ReadingArtifactCleanup.removeUncommittedFiles(in: directory, papers: previous.state.papers)
            }
        }
    }

    func committedResearchState() -> (LibraryState, Int64)? { baseline }

    /// A bounded batch keeps one idle pass responsive. Remaining rows stay pending and the same
    /// source generation is retried; publishing is idempotent.
    func researchMaintenanceSnapshot(
        pendingLimit: Int = 256
    ) throws -> ResearchMaintenanceSnapshot? {
        guard let baseline else { return nil }
        return try Self.database(at: databaseURL) { db in
            let researchRevision = try Self.integer(db, "SELECT revision FROM research_generation WHERE id=1")
            let pending = try Self.readPendingResearchEvents(db, limit: pendingLimit)
            return ResearchMaintenanceSnapshot(
                state: baseline.state, libraryRevision: baseline.revision,
                researchRevision: researchRevision, pendingEvents: pending,
                indexState: try Self.readResearchIndexState(db))
        }
    }

    /// Reading, translation and note authoring are observations, not edits to the library. A
    /// per-paper/day key keeps a long reading session from flooding the event log.
    @discardableResult
    public func recordPaperEngagement(_ engagement: ResearchEngagement, paperID: UUID, at date: Date = Date()) throws
        -> Bool
    {
        guard let previous = baseline, previous.state.papers.contains(where: { $0.id == paperID }) else {
            return false
        }
        let day = Calendar(identifier: .gregorian).startOfDay(for: date)
        let dayKey = String(Int(day.timeIntervalSince1970))
        let revision = engagement.rawValue + "-" + dayKey
        return try Self.database(at: databaseURL) { db in
            try Self.transaction(db) {
                let inserted: Bool = try LibraryRecords.statement(
                    db,
                    """
                    INSERT OR IGNORE INTO research_events(
                        event_key,kind,record_id,paper_id,shelf_id,record_revision,occurred_at,library_revision
                    ) VALUES(?,?,?,?,?,?,?,?)
                    """
                ) { stmt in
                    try Self.bindResearchText(
                        "paperEngaged|\(paperID.uuidString)|\(revision)", to: 1, in: stmt)
                    try Self.bindResearchText(ResearchEvent.Kind.paperEngaged.rawValue, to: 2, in: stmt)
                    try Self.bindResearchText(paperID.uuidString, to: 3, in: stmt)
                    try Self.bindResearchText(paperID.uuidString, to: 4, in: stmt)
                    try Self.bindResearchOptional(
                        previous.state.paperShelfIDs[paperID.uuidString]?.uuidString, to: 5, in: stmt)
                    try Self.bindResearchText(revision, to: 6, in: stmt)
                    sqlite3_bind_double(stmt, 7, date.timeIntervalSinceReferenceDate)
                    sqlite3_bind_int64(stmt, 8, previous.revision)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                    return sqlite3_changes(db) > 0
                }
                if inserted {
                    try Self.execute(db, "UPDATE research_generation SET revision=revision+1 WHERE id=1")
                }
                return inserted
            }
        }
    }

    func researchIndexState() throws -> ResearchIndexState? {
        try Self.database(at: databaseURL) { db in try Self.readResearchIndexState(db) }
    }

    func pendingResearchEvents(limit: Int = 256) throws -> [StoredResearchEvent] {
        guard limit > 0 else { return [] }
        return try Self.database(at: databaseURL) { db in
            try Self.readPendingResearchEvents(db, limit: limit)
        }
    }

    func researchEventCounts() throws -> (total: Int, pending: Int) {
        try Self.database(at: databaseURL) { db in
            let total = try Self.integer(db, "SELECT count(*) FROM research_events")
            let pending = try Self.integer(
                db, "SELECT count(*) FROM research_events WHERE processed_research_revision IS NULL")
            return (Int(total), Int(pending))
        }
    }

    func researchGeneration() throws -> Int64 {
        try Self.database(at: databaseURL) { db in
            try Self.integer(db, "SELECT revision FROM research_generation WHERE id=1")
        }
    }

    /// A single local worker owns index maintenance for a bounded interval. The lease is stored in
    /// SQLite so two app windows or a restarted process cannot publish overlapping work.
    func acquireResearchLease(owner: UUID, now: Date = Date(), duration: TimeInterval = 300) throws -> Bool {
        guard duration > 0 else { return false }
        let expires = now.addingTimeInterval(duration).timeIntervalSinceReferenceDate
        return try Self.database(at: databaseURL) { db in
            try Self.transaction(db) {
                let current: (owner: String, expires: Double)? =
                    try LibraryRecords.statement(
                        db, "SELECT owner,expires_at FROM research_maintenance_lease WHERE id=1"
                    ) { stmt in
                        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                        guard let owner = sqlite3_column_text(stmt, 0) else {
                            throw LibraryRecords.writeFailure
                        }
                        return (String(cString: owner), sqlite3_column_double(stmt, 1))
                    }
                if let current, current.expires > now.timeIntervalSinceReferenceDate { return false }
                try LibraryRecords.statement(
                    db,
                    "INSERT OR REPLACE INTO research_maintenance_lease(id,owner,expires_at) VALUES(1,?,?)"
                ) { stmt in
                    try Self.bindResearchText(owner.uuidString, to: 1, in: stmt)
                    sqlite3_bind_double(stmt, 2, expires)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                }
                return true
            }
        }
    }

    /// A long rebuild renews its lease between the expensive phases. The owner check prevents a
    /// worker whose lease expired from reviving a lease another window already took.
    func renewResearchLease(owner: UUID, now: Date = Date(), duration: TimeInterval = 300) throws -> Bool {
        guard duration > 0 else { return false }
        let expires = now.addingTimeInterval(duration).timeIntervalSinceReferenceDate
        return try Self.database(at: databaseURL) { db in
            try LibraryRecords.statement(
                db, "UPDATE research_maintenance_lease SET expires_at=? WHERE id=1 AND owner=?"
            ) { stmt in
                sqlite3_bind_double(stmt, 1, expires)
                try Self.bindResearchText(owner.uuidString, to: 2, in: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                return sqlite3_changes(db) > 0
            }
        }
    }

    func releaseResearchLease(owner: UUID) throws {
        try Self.database(at: databaseURL) { db in
            try LibraryRecords.statement(
                db, "DELETE FROM research_maintenance_lease WHERE id=1 AND owner=?"
            ) { stmt in
                try Self.bindResearchText(owner.uuidString, to: 1, in: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
            }
        }
    }

    /// Publish the derived brief checkpoint and its watermark atomically. A worker that observed
    /// an older source generation or an older checkpoint cannot advance the watermark or mark
    /// newer events as processed.
    func publishResearchIndex(
        _ data: Data, previousPayload: Data?, libraryRevision: Int64, researchRevision: Int64,
        lastEventSequence: Int64, auditedAt: Date?
    ) throws -> Bool {
        guard data.count <= 32 * 1024 * 1024 else { return false }
        return try Self.database(at: databaseURL) { db in
            try Self.transaction(db) {
                guard try Self.integer(db, "SELECT revision FROM library_generation WHERE id=1") == libraryRevision,
                    try Self.integer(db, "SELECT revision FROM research_generation WHERE id=1") == researchRevision
                else { return false }
                if let previousPayload, try Self.checkpoint(db, .brief) != previousPayload { return false }
                try Self.execute(
                    db,
                    "CREATE TABLE IF NOT EXISTS research_brief(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)"
                )
                try Self.writeCheckpoint(data, db, .brief)
                let prior = try Self.readResearchIndexState(db)
                let watermark = max(lastEventSequence, prior?.lastEventSequence ?? 0)
                let state = ResearchIndexState(
                    lastResearchRevision: researchRevision, lastEventSequence: watermark,
                    lastAuditAt: auditedAt ?? prior?.lastAuditAt, format: 1)
                let payload = try JSONEncoder().encode(state)
                try Self.execute(
                    db,
                    "CREATE TABLE IF NOT EXISTS research_index_state(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)"
                )
                try Self.writeCheckpoint(payload, db, .index)
                if watermark > 0 {
                    try LibraryRecords.statement(
                        db,
                        "UPDATE research_events SET processed_research_revision=? WHERE sequence<=? AND processed_research_revision IS NULL"
                    ) { stmt in
                        sqlite3_bind_int64(stmt, 1, researchRevision)
                        sqlite3_bind_int64(stmt, 2, watermark)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
                    }
                    try Self.pruneProcessedResearchEvents(db)
                }
                return true
            }
        }
    }

    enum ResearchTable: String {
        case brief = "research_brief"
        case sleep = "memory_sleep"
        case index = "research_index_state"
    }

    private static func ensureResearchSchema(_ db: OpaquePointer) throws {
        try execute(
            db,
            """
            CREATE TABLE IF NOT EXISTS research_events (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                event_key TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                record_id TEXT NOT NULL,
                paper_id TEXT,
                shelf_id TEXT,
                record_revision TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                library_revision INTEGER NOT NULL,
                processed_research_revision INTEGER
            )
            """)
        try execute(
            db,
            "CREATE INDEX IF NOT EXISTS research_events_pending ON research_events(processed_research_revision,sequence)"
        )
        try execute(
            db,
            "CREATE TABLE IF NOT EXISTS research_generation(id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL)"
        )
        try execute(db, "INSERT OR IGNORE INTO research_generation VALUES(1,0)")
        try execute(
            db,
            "CREATE TABLE IF NOT EXISTS research_index_state(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)"
        )
        try execute(
            db,
            """
            CREATE TABLE IF NOT EXISTS research_maintenance_lease(
                id INTEGER PRIMARY KEY CHECK(id=1), owner TEXT NOT NULL, expires_at REAL NOT NULL
            )
            """)
        try execute(
            db,
            """
            CREATE TABLE IF NOT EXISTS note_relations(
                source_id TEXT PRIMARY KEY, source_modified REAL NOT NULL, payload BLOB NOT NULL
            )
            """)
        try execute(
            db,
            """
            CREATE TABLE IF NOT EXISTS memory_audit(
                id INTEGER PRIMARY KEY AUTOINCREMENT, memory_id TEXT NOT NULL,
                action TEXT NOT NULL, trigger_hash TEXT NOT NULL, occurred_at REAL NOT NULL
            )
            """)
    }

    private static func appendResearchEvents(
        _ events: [ResearchEvent], libraryRevision: Int64, db: OpaquePointer
    ) throws {
        guard !events.isEmpty else { return }
        for event in events {
            try LibraryRecords.statement(
                db,
                """
                INSERT OR IGNORE INTO research_events(
                    event_key,kind,record_id,paper_id,shelf_id,record_revision,occurred_at,library_revision
                ) VALUES(?,?,?,?,?,?,?,?)
                """
            ) { stmt in
                try Self.bindResearchText(event.key, to: 1, in: stmt)
                try Self.bindResearchText(event.kind.rawValue, to: 2, in: stmt)
                try Self.bindResearchText(event.recordID.uuidString, to: 3, in: stmt)
                try Self.bindResearchOptional(event.paperID?.uuidString, to: 4, in: stmt)
                try Self.bindResearchOptional(event.shelfID?.uuidString, to: 5, in: stmt)
                try Self.bindResearchText(event.recordRevision, to: 6, in: stmt)
                sqlite3_bind_double(stmt, 7, event.occurredAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_int64(stmt, 8, libraryRevision)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
            }
        }
    }

    /// The derived index never needs the complete processed history to rebuild; the main library
    /// is authoritative. Keep a bounded recent tail so diagnostics stay useful without growing
    /// the event table for the lifetime of the library.
    /// Local audit for silent memory changes. The trigger is hashed; no prose is retained.
    /// Persist salience recall telemetry (`lastRecalledAt`, `recallCount`) without advancing
    /// `library_generation` or `research_generation`, so read-only memory recall never races
    /// concurrent sleep/brief publication or emits spurious research events.
    public func recordMemoryRecall(_ ids: Set<UUID>, at date: Date = Date()) throws {
        guard var current = baseline, !ids.isEmpty else { return }
        var changedIndices: [Int] = []
        for index in current.state.memories.indices {
            let item = current.state.memories[index]
            guard ids.contains(item.id), item.isActive, !item.userEdited, !item.isResponsePreference else { continue }
            current.state.memories[index].recordRecall(at: date)
            changedIndices.append(index)
        }
        guard !changedIndices.isEmpty else { return }
        let updated = try Self.database(at: databaseURL) { db -> Bool in
            try Self.transaction(db) {
                guard try Self.integer(db, "SELECT revision FROM library_generation WHERE id=1") == current.revision
                else { return false }
                let records = LibraryRecords(db)
                for index in changedIndices {
                    try records.updateMemory(current.state.memories[index])
                }
                return true
            }
        }
        if updated {
            baseline = current
        }
    }

    public func recordMemoryAudit(memoryID: UUID, action: String, trigger: String) throws {
        let hash = SHA256.hash(data: Data(trigger.utf8)).map { String(format: "%02x", $0) }.joined()
        try Self.database(at: databaseURL) { db in
            try LibraryRecords.statement(
                db,
                "INSERT INTO memory_audit(memory_id,action,trigger_hash,occurred_at) VALUES(?,?,?,?)"
            ) { stmt in
                try Self.bindResearchText(memoryID.uuidString, to: 1, in: stmt)
                try Self.bindResearchText(action, to: 2, in: stmt)
                try Self.bindResearchText(hash, to: 3, in: stmt)
                sqlite3_bind_double(stmt, 4, Date().timeIntervalSinceReferenceDate)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
            }
        }
    }

    func memoryAuditCount() throws -> Int {
        try Self.database(at: databaseURL) { db in
            Int(try Self.integer(db, "SELECT count(*) FROM memory_audit"))
        }
    }

    /// Derived note-neighbour cache. The source note revision is the cache key; target revisions
    /// are checked by the caller before using an edge. The authoritative notes remain in
    /// `library_records`.
    public func noteRelations(sourceID: UUID, sourceModifiedAt: Date) throws -> [NoteRelation]? {
        try Self.database(at: databaseURL) { db in
            try LibraryRecords.statement(
                db, "SELECT source_modified,payload FROM note_relations WHERE source_id=?"
            ) { stmt in
                try Self.bindResearchText(sourceID.uuidString, to: 1, in: stmt)
                guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                guard abs(sqlite3_column_double(stmt, 0) - sourceModifiedAt.timeIntervalSinceReferenceDate) < 0.001
                else { return nil }
                guard let data = try? LibraryRecords.blob(stmt, column: 1),
                    data.count <= 256 * 1024,
                    let relations = try? JSONDecoder().decode([NoteRelation].self, from: data)
                else { return nil }
                return relations
            }
        }
    }

    public func saveNoteRelations(_ relations: [NoteRelation], sourceID: UUID, sourceModifiedAt: Date) throws {
        let data = try JSONEncoder().encode(relations)
        guard data.count <= 256 * 1024 else { return }
        try Self.database(at: databaseURL) { db in
            try LibraryRecords.statement(
                db, "INSERT OR REPLACE INTO note_relations(source_id,source_modified,payload) VALUES(?,?,?)"
            ) { stmt in
                try Self.bindResearchText(sourceID.uuidString, to: 1, in: stmt)
                sqlite3_bind_double(stmt, 2, sourceModifiedAt.timeIntervalSinceReferenceDate)
                try LibraryRecords.bind(data, to: 3, in: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
            }
        }
    }

    static let retainedProcessedEvents = 4_096

    static func pruneProcessedResearchEvents(
        _ db: OpaquePointer, keeping: Int = retainedProcessedEvents
    ) throws {
        guard keeping >= 0 else { return }
        try execute(
            db,
            """
            DELETE FROM research_events
            WHERE processed_research_revision IS NOT NULL
              AND sequence <= (
                SELECT sequence FROM research_events
                WHERE processed_research_revision IS NOT NULL
                ORDER BY sequence DESC LIMIT 1 OFFSET \(keeping)
              )
            """)
    }

    private static func readPendingResearchEvents(_ db: OpaquePointer, limit: Int) throws -> [StoredResearchEvent] {
        try LibraryRecords.statement(
            db,
            """
            SELECT sequence,kind,record_id,paper_id,shelf_id,record_revision,occurred_at
            FROM research_events WHERE processed_research_revision IS NULL
            ORDER BY sequence LIMIT ?
            """
        ) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(limit))
            var result: [StoredResearchEvent] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW, let kindText = sqlite3_column_text(stmt, 1),
                    let kind = ResearchEvent.Kind(rawValue: String(cString: kindText)),
                    let recordText = sqlite3_column_text(stmt, 2),
                    let recordRevision = sqlite3_column_text(stmt, 5)
                else { throw LibraryRecords.writeFailure }
                let paperID = sqlite3_column_text(stmt, 3).flatMap { UUID(uuidString: String(cString: $0)) }
                let shelfID = sqlite3_column_text(stmt, 4).flatMap { UUID(uuidString: String(cString: $0)) }
                let event = ResearchEvent(
                    kind: kind, recordID: try Self.researchUUID(recordText), paperID: paperID, shelfID: shelfID,
                    recordRevision: String(cString: recordRevision),
                    occurredAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6)))
                result.append(StoredResearchEvent(sequence: sqlite3_column_int64(stmt, 0), event: event))
            }
        }
    }

    private static func readResearchIndexState(_ db: OpaquePointer) throws -> ResearchIndexState? {
        guard let data = try checkpoint(db, .index) else { return nil }
        return try? JSONDecoder().decode(ResearchIndexState.self, from: data)
    }

    private static func researchUUID(_ text: UnsafePointer<UInt8>) throws -> UUID {
        guard let id = UUID(uuidString: String(cString: text)) else { throw LibraryRecords.writeFailure }
        return id
    }

    private static var researchTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func bindResearchText(_ text: String, to column: Int32, in stmt: OpaquePointer) throws {
        guard sqlite3_bind_text(stmt, column, text, -1, researchTransient) == SQLITE_OK else {
            throw LibraryRecords.writeFailure
        }
    }

    private static func bindResearchOptional(_ text: String?, to column: Int32, in stmt: OpaquePointer) throws {
        if let text {
            try bindResearchText(text, to: column, in: stmt)
        } else {
            sqlite3_bind_null(stmt, column)
        }
    }

    private static func hasResearchCheckpoint(_ db: OpaquePointer, _ table: ResearchTable) throws -> Bool {
        try integer(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='\(table.rawValue)'") != 0
    }

    func readResearchCheckpoint(_ table: ResearchTable = .brief) throws -> Data? {
        try Self.database(at: databaseURL) { db in try Self.checkpoint(db, table) }
    }

    private static func checkpoint(_ db: OpaquePointer, _ table: ResearchTable) throws -> Data? {
        guard try hasResearchCheckpoint(db, table) else { return nil }
        return try LibraryRecords.statement(
            db, "SELECT payload FROM \(table.rawValue) WHERE id=1 AND length(payload)<=33554432"
        ) { stmt in
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw LibraryRecords.writeFailure }
            return try LibraryRecords.blob(stmt, column: 0)
        }
    }

    private static func writeCheckpoint(_ data: Data, _ db: OpaquePointer, _ table: ResearchTable) throws {
        try LibraryRecords.statement(db, "INSERT OR REPLACE INTO \(table.rawValue)(id,payload) VALUES(1,?)") { stmt in
            try LibraryRecords.bind(data, to: 1, in: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw LibraryRecords.writeFailure }
        }
    }

    /// A derived publication never changes the authoritative library generation. A stale worker,
    /// including one in another process, cannot replace the result for a later committed revision.
    func publishResearchCheckpoint(
        _ data: Data, revision: Int64, table: ResearchTable = .brief, previousPayload: Data? = nil
    ) throws -> Bool {
        guard data.count <= 32 * 1024 * 1024 else { return false }
        return try Self.database(at: databaseURL) { db in
            try Self.transaction(db) {
                guard try Self.integer(db, "SELECT revision FROM library_generation WHERE id=1") == revision else {
                    return false
                }
                if table == .sleep {
                    try Task.checkCancellation()
                    guard try Self.checkpoint(db, table) == previousPayload else { return false }
                }
                try Self.execute(
                    db,
                    "CREATE TABLE IF NOT EXISTS \(table.rawValue)(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)"
                )
                try Self.writeCheckpoint(data, db, table)
                return true
            }
        }
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
        let suppressedMemoryFingerprints: Set<String>?

        init(_ state: LibraryState) {
            recordFormat = 2
            version = state.version
            shelves = state.shelves
            paperShelfIDs = state.paperShelfIDs
            manualPaperIDs = state.manualPaperIDs
            preferredSort = state.preferredSort
            suppressedMemoryFingerprints =
                state.suppressedMemoryFingerprints.isEmpty ? nil : state.suppressedMemoryFingerprints
        }

        var state: LibraryState {
            var state = LibraryState()
            state.shelves = shelves
            state.paperShelfIDs = paperShelfIDs
            state.manualPaperIDs = manualPaperIDs
            state.preferredSort = preferredSort
            state.suppressedMemoryFingerprints = suppressedMemoryFingerprints ?? []
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

    static func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
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

    static func database<T>(at url: URL, body: (OpaquePointer) throws -> T) throws -> T {
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

    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ReaderError.message("书库事务失败，原有内容未被替换。")
        }
    }
}
