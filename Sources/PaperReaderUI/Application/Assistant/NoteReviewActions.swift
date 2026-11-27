import Foundation
import Observation
import PaperReaderKit

/// A monotonic review watermark. A limited pass records the timestamp of the last processed note
/// plus the IDs sharing that timestamp, so the unprocessed tail is never skipped when more than
/// one page of notes changed.
struct NoteReviewCursor: Codable, Equatable, Sendable {
    var date: Date
    var processedIDs: Set<UUID> = []

    static func stamp(_ note: ReadingNote) -> Date { max(note.modifiedAt, note.createdAt) }

    func needsReview(_ note: ReadingNote, at stamp: Date) -> Bool {
        if stamp > date.addingTimeInterval(0.001) { return true }
        return abs(stamp.timeIntervalSince(date)) <= 0.001 && !processedIDs.contains(note.id)
    }

    static func advanced(
        _ cursor: NoteReviewCursor, processed: [NoteReviewInput.Target], startedAt: Date, hasMore: Bool
    ) -> NoteReviewCursor {
        guard hasMore,
            let boundary = processed.map(\.modifiedAt).max()
        else { return NoteReviewCursor(date: startedAt) }
        let ids = Set(
            processed.filter { abs($0.modifiedAt.timeIntervalSince(boundary)) <= 0.001 }.map(\.noteID))
        return NoteReviewCursor(date: max(cursor.date, boundary), processedIDs: ids)
    }
}

struct NoteReviewInput: Encodable {
    struct Relation: Encodable {
        let noteID: UUID
        let title: String
        let modifiedAt: Date
        let kind: String
        let overlap: Int
        let excerpt: String
    }
    struct Target: Encodable {
        let noteID: UUID
        let title: String
        let modifiedAt: Date
        let markdown: String
        let relations: [Relation]
    }
    let targets: [Target]
}

struct NoteReviewPage {
    let targets: [NoteReviewInput.Target]
    let hasMore: Bool
}

@MainActor @Observable
final class NoteReviewSession {
    private(set) var running = false
    var message: String?
    private let store: LibraryStore
    let semantic: SemanticPassageIndex
    private let defaultsKey: String
    private var job: Task<Void, Never>?
    private var nextCheck = Date.distantPast
    private var cursor: NoteReviewCursor
    private var foregroundWork = 0
    private static let pageSize = 8
    /// Test seam: production uses the configured model service.
    @ObservationIgnored var reviewOverride: (@MainActor (ReaderModel, NoteReviewInput) async throws -> String)?
    /// Test seam: hosts or CI may themselves be in Low Power Mode.
    @ObservationIgnored var isLowPowerModeEnabled: @MainActor () -> Bool = {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: defaultsKey + ".enabled")
            if !enabled { interrupt() }
        }
    }

    var interval: TimeInterval {
        didSet {
            UserDefaults.standard.set(interval, forKey: defaultsKey + ".interval")
            nextCheck = .distantPast
        }
    }

    init(store: LibraryStore, root: URL, encoder: (any SemanticTextEncoder)? = nil, minimumScore: Float? = nil) {
        self.store = store
        semantic = SemanticPassageIndex(
            encoder: encoder,
            cacheURL: root.appendingPathComponent("DerivedIndexes", isDirectory: true)
                .appendingPathComponent("note-relations.sqlite"),
            minimumScore: minimumScore)
        defaultsKey = "pagewise.noteReview." + root.standardizedFileURL.path
        enabled = UserDefaults.standard.object(forKey: defaultsKey + ".enabled") as? Bool ?? false
        interval = UserDefaults.standard.object(forKey: defaultsKey + ".interval") as? TimeInterval ?? 6 * 3600
        if let data = UserDefaults.standard.data(forKey: defaultsKey + ".cursor"),
            let saved = try? JSONDecoder().decode(NoteReviewCursor.self, from: data)
        {
            cursor = saved
        } else {
            // Migrate the pre-cursor watermark. A legacy value of zero reviews the whole backlog once.
            let legacy = UserDefaults.standard.object(forKey: defaultsKey + ".lastRun") as? TimeInterval ?? 0
            cursor = NoteReviewCursor(date: Date(timeIntervalSinceReferenceDate: legacy))
        }
    }

    func beginForegroundWork() {
        foregroundWork += 1
        interrupt()
    }

    func endForegroundWork() {
        foregroundWork = max(0, foregroundWork - 1)
    }

    func interrupt() {
        job?.cancel()
    }

    func run(reader: ReaderModel, automatic: Bool, withModel: Bool) {
        guard !running, reader.loaded, !reader.busyAI, !reader.isImporting else { return }
        #if os(iOS)
            if automatic { guard reader.isActive else { return } }
        #endif
        if automatic {
            guard enabled, foregroundWork == 0, !reader.memorySleep.running, !reader.busyAI, !reader.isImporting,
                !isLowPowerModeEnabled(),
                Date().timeIntervalSince(reader.lastInteraction) >= 120,
                Date() >= nextCheck, !withModel || !reader.modelSettings.model.isEmpty
            else { return }
        }
        guard withModel else { return }
        let startedAt = Date()
        running = true
        message = nil
        job = Task(priority: .utility) { [weak self, weak reader] in
            guard let self, let reader else { return }
            defer {
                running = false
                job = nil
            }
            do {
                let page = try await self.reviewTargets(reader: reader, cursor: self.cursor)
                guard !page.targets.isEmpty else {
                    self.nextCheck = Date().addingTimeInterval(self.interval)
                    return
                }
                let input = NoteReviewInput(targets: page.targets)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let response =
                    if let reviewOverride = self.reviewOverride {
                        try await reviewOverride(reader, input)
                    } else {
                        try await reader.reviewNoteBatch(input)
                    }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let report = try decoder.decode(NoteReviewReport.self, from: Data(response.utf8))
                let changed = try await reader.applyNoteReview(report, contexts: page.targets)
                self.advanceCursor(page: page, startedAt: startedAt)
                if changed > 0 {
                    message = "已静默更新 \(changed) 条笔记正文"
                }
                nextCheck = Date().addingTimeInterval(interval)
            } catch {
                nextCheck = Date().addingTimeInterval(min(300, interval))
                if !automatic { message = error.localizedDescription }
            }
        }
    }

    private func advanceCursor(page: NoteReviewPage, startedAt: Date) {
        cursor = NoteReviewCursor.advanced(
            cursor, processed: page.targets, startedAt: startedAt, hasMore: page.hasMore)
        if let data = try? JSONEncoder().encode(cursor) {
            UserDefaults.standard.set(data, forKey: defaultsKey + ".cursor")
        }
    }

    private func reviewTargets(reader: ReaderModel, cursor: NoteReviewCursor) async throws -> NoteReviewPage {
        let notes = reader.state.readingNotes.filter { $0.deletedAt == nil }
        let stamps = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, NoteReviewCursor.stamp($0)) })
        let pending = notes.filter { note in
            guard let stamp = stamps[note.id] else { return false }
            return cursor.needsReview(note, at: stamp)
        }.sorted {
            let left = stamps[$0.id] ?? $0.modifiedAt
            let right = stamps[$1.id] ?? $1.modifiedAt
            if left != right { return left < right }
            return $0.id.uuidString < $1.id.uuidString
        }
        // Recently active papers can refresh context, but only after every genuine pending note
        // had a chance to run. Otherwise a large recent set could starve the cursor forever.
        let recentPaperIDs = Set(
            reader.state.papers.filter { $0.addedAt > cursor.date }.map(\.id)
                + reader.state.reading.filter { $0.end > cursor.date }.map(\.paperID))
        var selected = Array(pending.prefix(Self.pageSize))
        if selected.count < Self.pageSize {
            let existing = Set(selected.map(\.id))
            let pendingIDs = Set(pending.map(\.id))
            let extras = notes.filter {
                recentPaperIDs.contains($0.paperID) && !existing.contains($0.id)
                    && !pendingIDs.contains($0.id)
            }.sorted {
                let left = stamps[$0.id] ?? $0.modifiedAt
                let right = stamps[$1.id] ?? $1.modifiedAt
                return left > right
            }
            selected += extras.prefix(Self.pageSize - selected.count)
        }
        let titles = Dictionary(
            reader.state.papers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Keep a single stable corpus across all targets in this batch so `SemanticPassageIndex`
        // warms once instead of cancelling its background warmup on every target note.
        let allPassages = notes.map { SemanticPassage(sourceID: $0.id, text: String($0.markdown.prefix(900))) }
        var semanticPrepared = false
        var targets: [NoteReviewInput.Target] = []
        for note in selected {
            let cached = try? await store.noteRelations(sourceID: note.id, sourceModifiedAt: note.modifiedAt)
            let cachedRelations: [(note: ReadingNote, overlap: Int, kind: NoteRelation.Kind)]?
            if let cached {
                let valid = cached.compactMap { relation -> (ReadingNote, Int, NoteRelation.Kind)? in
                    guard let other = byID[relation.targetID], other.deletedAt == nil,
                        abs(other.modifiedAt.timeIntervalSince(relation.targetModifiedAt)) < 0.001
                    else { return nil }
                    return (other, relation.overlap, relation.kind)
                }
                cachedRelations = valid.count == cached.count ? valid : nil
            } else {
                cachedRelations = nil
            }
            let relations: [(note: ReadingNote, overlap: Int, kind: NoteRelation.Kind)]
            if let cachedRelations {
                relations = cachedRelations
            } else {
                if !semanticPrepared, !allPassages.isEmpty, await semantic.isAvailable() {
                    try? await semantic.prepare(allPassages)
                    semanticPrepared = true
                }
                relations = await computeRelations(for: note, notes: notes, allPassages: allPassages)
                try? await store.saveNoteRelations(
                    relations.map {
                        NoteRelation(
                            sourceID: note.id, targetID: $0.note.id, kind: $0.kind, overlap: $0.overlap,
                            targetModifiedAt: $0.note.modifiedAt)
                    }, sourceID: note.id, sourceModifiedAt: note.modifiedAt)
            }
            let inputRelations = relations.prefix(4).map { other, overlap, kind in
                NoteReviewInput.Relation(
                    noteID: other.id,
                    title: String(PaperTitle.display(titles[other.paperID] ?? "论文").prefix(160)),
                    modifiedAt: other.modifiedAt,
                    kind: kind.rawValue,
                    overlap: overlap,
                    excerpt: String(ReadingNoteMemoryIndex.searchableBody(other.markdown).prefix(120)))
            }
            targets.append(
                NoteReviewInput.Target(
                    noteID: note.id,
                    title: String(PaperTitle.display(titles[note.paperID] ?? "论文").prefix(160)),
                    modifiedAt: note.modifiedAt,
                    markdown: String(note.markdown.prefix(900)),
                    relations: Array(inputRelations)))
        }
        return NoteReviewPage(targets: targets, hasMore: pending.count > Self.pageSize)
    }

    private func computeRelations(
        for note: ReadingNote, notes: [ReadingNote], allPassages: [SemanticPassage]
    ) async -> [(note: ReadingNote, overlap: Int, kind: NoteRelation.Kind)] {
        let terms = Retriever.expandedTokens(note.markdown)
        let others = notes.filter { $0.id != note.id }
        let byID = Dictionary(others.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allowed = Set(byID.keys)
        if !allowed.isEmpty, !allPassages.isEmpty {
            if let matches = try? await semantic.matches(
                note.markdown, passages: allPassages, allowed: allowed, limit: 8),
                !matches.isEmpty
            {
                return matches.compactMap { match -> (ReadingNote, Int, NoteRelation.Kind)? in
                    guard let other = byID[match.passage.sourceID] else { return nil }
                    let overlap = terms.intersection(Retriever.expandedTokens(other.markdown)).count
                    let kind = Self.relationKind(note.markdown, other.markdown)
                    return (other, overlap, kind)
                }
            }
        }
        return
            others
            .compactMap { other -> (ReadingNote, Int, NoteRelation.Kind)? in
                let overlap = terms.intersection(Retriever.expandedTokens(other.markdown)).count
                guard overlap >= 2 else { return nil }
                return (other, overlap, Self.relationKind(note.markdown, other.markdown))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map { $0 }
    }

    static func relationKind(_ lhs: String, _ rhs: String) -> NoteRelation.Kind {
        // Numbers alone do not establish a conflict: different tables, seeds, years and
        // hyperparameters legitimately use different values. The model receives the excerpts
        // and decides whether two notes disagree; the local cache only records a coarse hint.
        let negated = { (text: String) -> Bool in
            text.range(of: #"(?i)\b(?:not|no|never|without)\b|不|没有|未|并非|无法"#, options: .regularExpression) != nil
        }
        if negated(lhs) != negated(rhs) { return .conflict }
        return .similar
    }

}

struct NoteRevisionMutation {
    struct Entry {
        let noteID: UUID
        let expectedModifiedAt: Date
        let markdown: String
        let sources: ChatSourceVersions
    }

    let entries: [Entry]

    @MainActor
    func apply(to state: inout LibraryState, excluding pending: Set<UUID>) -> Int {
        var changed = 0
        for entry in entries {
            guard let index = state.readingNotes.firstIndex(where: { $0.id == entry.noteID }),
                state.readingNotes[index].deletedAt == nil,
                abs(entry.expectedModifiedAt.timeIntervalSince(state.readingNotes[index].modifiedAt)) < 0.001,
                entry.sources.isCurrent(in: state, excluding: pending),
                ReaderModel.isSmallNoteRevision(from: state.readingNotes[index].markdown, to: entry.markdown)
            else { continue }
            var note = state.readingNotes[index]
            if note.applyAIRevision(entry.markdown, sources: entry.sources) {
                state.readingNotes[index] = note
                changed += 1
            }
        }
        return changed
    }
}

struct NoteReviewReport: Decodable {
    struct Revision: Decodable {
        let noteID: UUID
        let modifiedAt: Date?
        let markdown: String

        enum CodingKeys: String, CodingKey {
            case noteID = "note_id"
            case modifiedAt = "modified_at"
            case markdown
        }
    }
    let revisions: [Revision]
}

extension ReaderModel {
    func reviewNoteBatch(_ input: NoteReviewInput) async throws -> String {
        let config = modelSettings
        let key = try await modelKey(for: config)
        guard !key.isEmpty else { throw ReaderError.message("请在设置中连接模型服务。") }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = String(decoding: try encoder.encode(input), as: UTF8.self)
        return try await client.complete(
            settings: config, key: key,
            system: """
                你是读者笔记的静默维护员。targets 是读者已有笔记和少量关系摘录，excerpt 是唯一可引用的新证据。
                只输出 JSON {"revisions":[{"note_id":"UUID","modified_at":"ISO8601","markdown":"完整的新笔记正文"}]}。
                这是“局部修订”，不是重写：
                - 保留原文的句子、顺序、语气、标题和 Markdown 结构；只改直接受新证据影响的词句，最多调整一两处；
                - 新正文与原文的字符改动通常不超过 25%，长度保持在原文的 70%–140%；
                - 可以补一句限定条件、更正一个数字/否定、指出相似或冲突，但不得大段扩写、重排、换标题或改写成更“漂亮”的文章；
                - 原话、数字、否定、条件、引用和适用范围必须保留；冲突必须并列，不得静默选边；
                - 只有新增阅读/笔记或关系证据确实支持时才更新；没有明确的小改动、需要大改、或不确定时返回 {"revisions":[]}；
                - 若 target 与 relation 的条件相同但数字/否定不同，且 relation.modified_at 晚于 target.modified_at，优先在较旧的笔记末尾追加一句简短的“新近复现/冲突：…（保留旧值）”或补上样本量/条件，不要删除旧数字，也不要把两个数字合并成新的确定结论；
                - 如果 target 本身已经是较新、更具体的一方，则不要为了“对称”强行改写它。
                不引用未提供的原文和外部链接；不写模型自己的建议口吻，直接写成读者笔记正文。
                """, user: payload, jsonOutput: true, maxOutputTokens: 800)
    }

    func applyNoteReview(
        _ report: NoteReviewReport, contexts: [NoteReviewInput.Target] = []
    ) async throws -> Int {
        var entries: [NoteRevisionMutation.Entry] = []
        for revision in report.revisions.prefix(8) {
            guard let index = state.readingNotes.firstIndex(where: { $0.id == revision.noteID }),
                state.readingNotes[index].deletedAt == nil,
                revision.markdown.count <= 20_000,
                !revision.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            // The model often echoes a related note's date. The runtime context, not the model's
            // date, is authoritative for detecting edits while the request was in flight.
            let expectedDate =
                contexts.first(where: { $0.noteID == revision.noteID })?.modifiedAt
                ?? state.readingNotes[index].modifiedAt
            guard abs(expectedDate.timeIntervalSince(state.readingNotes[index].modifiedAt)) < 0.001 else {
                continue
            }
            var sources = ChatSourceVersions()
            var sourceStillValid = true
            if let context = contexts.first(where: { $0.noteID == revision.noteID }) {
                for relation in context.relations {
                    guard let source = state.readingNotes.first(where: { $0.id == relation.noteID }),
                        source.deletedAt == nil,
                        abs(source.modifiedAt.timeIntervalSince(relation.modifiedAt)) < 0.001
                    else {
                        sourceStillValid = false
                        break
                    }
                    sources.include(source)
                }
            }
            guard sourceStillValid,
                Self.isSmallNoteRevision(from: state.readingNotes[index].markdown, to: revision.markdown)
            else { continue }
            entries.append(
                .init(
                    noteID: revision.noteID, expectedModifiedAt: expectedDate,
                    markdown: revision.markdown, sources: sources))
        }
        guard !entries.isEmpty else { return 0 }
        let beforeRevisions = Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in
                state.readingNotes.first { $0.id == entry.noteID }.map { ($0.id, $0.revisions?.count ?? 0) }
            })
        guard await save(noteRevisionMutation: NoteRevisionMutation(entries: entries)) else {
            throw ReaderError.message("笔记修订未能保存。")
        }
        return entries.reduce(into: 0) { count, entry in
            if let note = state.readingNotes.first(where: { $0.id == entry.noteID }),
                (note.revisions?.count ?? 0) > (beforeRevisions[entry.noteID] ?? 0)
            {
                count += 1
            }
        }
    }

    /// A silent pass may add or correct a clause, but it must not rewrite the reader's note.
    /// Append-only edits are allowed; otherwise compare a real Myers diff so a typo at the
    /// start and a clarification at the end do not cancel each other out.
    static func isSmallNoteRevision(from old: String, to new: String) -> Bool {
        guard old != new, !new.isEmpty else { return false }
        let oldCount = old.count
        let newCount = new.count
        // Appending a bounded clarification is always a local edit; a replacement must stay close.
        if new.contains(old) { return newCount <= oldCount + 400 }
        guard newCount >= max(1, oldCount * 7 / 10), newCount <= max(oldCount, 1) * 14 / 10 else {
            return false
        }
        let difference = new.difference(from: old)
        let changed = difference.count
        guard changed > 0 else { return false }
        return Double(changed) / Double(max(oldCount, newCount)) <= 0.30
    }
}
