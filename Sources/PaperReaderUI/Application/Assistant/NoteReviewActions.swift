import Foundation
import Observation
import PaperReaderKit

struct NoteReviewInput: Encodable {
    struct Relation: Encodable {
        let noteID: UUID
        let title: String
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

@MainActor @Observable
final class NoteReviewSession {
    private(set) var running = false
    var message: String?
    private let defaultsKey: String
    private var job: Task<Void, Never>?
    private var nextCheck = Date.distantPast

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: defaultsKey + ".enabled") }
    }

    var interval: TimeInterval {
        didSet { UserDefaults.standard.set(interval, forKey: defaultsKey + ".interval") }
    }

    init(root: URL) {
        defaultsKey = "pagewise.noteReview." + root.standardizedFileURL.path
        enabled = UserDefaults.standard.object(forKey: defaultsKey + ".enabled") as? Bool ?? false
        interval = UserDefaults.standard.object(forKey: defaultsKey + ".interval") as? TimeInterval ?? 6 * 3600
    }

    func run(reader: ReaderModel, automatic: Bool, withModel: Bool) {
        guard !running, reader.loaded else { return }
        if automatic {
            guard enabled, !reader.busyAI, !reader.isImporting,
                !ProcessInfo.processInfo.isLowPowerModeEnabled,
                Date().timeIntervalSince(reader.lastInteraction) >= 120,
                Date() >= nextCheck, !withModel || !reader.modelSettings.model.isEmpty
            else { return }
        }
        let lastRun = UserDefaults.standard.object(forKey: defaultsKey + ".lastRun") as? TimeInterval ?? 0
        let since = Date(timeIntervalSinceReferenceDate: lastRun)
        let targets = reviewTargets(reader: reader, since: since)
        guard !targets.isEmpty else {
            nextCheck = Date().addingTimeInterval(interval)
            return
        }
        guard withModel else { return }
        running = true
        message = nil
        job = Task(priority: .utility) { [weak self, weak reader] in
            guard let self, let reader else { return }
            defer {
                running = false
                job = nil
            }
            do {
                let input = NoteReviewInput(targets: targets)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let response = try await reader.reviewNoteBatch(input)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let report = try decoder.decode(NoteReviewReport.self, from: Data(response.utf8))
                let changed = try await reader.applyNoteReview(report)
                UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: defaultsKey + ".lastRun")
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

    private func reviewTargets(reader: ReaderModel, since: Date) -> [NoteReviewInput.Target] {
        let notes = reader.state.readingNotes.filter { $0.deletedAt == nil }
        let changed = notes.filter { $0.modifiedAt > since || $0.createdAt > since }
        let recentPaperIDs = Set(
            reader.state.papers.filter { $0.addedAt > since }.map(\.id)
                + reader.state.reading.filter { $0.end > since }.map(\.paperID))
        let selected = (changed + notes.filter { recentPaperIDs.contains($0.paperID) })
            .reduce(into: [ReadingNote]()) { result, note in
                if !result.contains(where: { $0.id == note.id }) { result.append(note) }
            }
            .prefix(8)
        let titles = Dictionary(
            reader.state.papers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let targets = selected.map { note -> NoteReviewInput.Target in
            let terms = Retriever.tokens(note.markdown)
            let relations =
                notes
                .filter { $0.id != note.id }
                .compactMap { other -> (ReadingNote, Int, String)? in
                    let otherTerms = Retriever.tokens(other.markdown)
                    let overlap = terms.intersection(otherTerms).count
                    guard overlap >= 2 else { return nil }
                    let kind = Self.relationKind(note.markdown, other.markdown) ?? "similar"
                    return (other, overlap, kind)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(4)
                .map { other, overlap, kind in
                    NoteReviewInput.Relation(
                        noteID: other.id,
                        title: String(PaperTitle.display(titles[other.paperID] ?? "论文").prefix(160)),
                        kind: kind,
                        overlap: overlap,
                        excerpt: String(ReadingNoteMemoryIndex.searchableBody(other.markdown).prefix(120)))
                }
            return NoteReviewInput.Target(
                noteID: note.id,
                title: String(PaperTitle.display(titles[note.paperID] ?? "论文").prefix(160)),
                modifiedAt: note.modifiedAt,
                markdown: String(note.markdown.prefix(900)),
                relations: Array(relations))
        }
        return Array(targets)
    }

    private static func relationKind(_ lhs: String, _ rhs: String) -> String? {
        let numbers = { (text: String) -> Set<String> in
            Set(text.matches(of: /\d+(?:\.\d+)?/).map { String($0.output) })
        }
        let negated = { (text: String) -> Bool in
            text.range(of: #"(?i)\b(?:not|no|never|without)\b|不|没有|未|并非|无法"#, options: .regularExpression) != nil
        }
        if negated(lhs) != negated(rhs) { return "conflict" }
        if !numbers(lhs).isEmpty, !numbers(rhs).isEmpty, numbers(lhs) != numbers(rhs) { return "conflict" }
        return nil
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
                - 只有新增阅读/笔记或关系证据确实支持时才更新；没有明确的小改动、需要大改、或不确定时返回 {"revisions":[]}。
                不引用未提供的原文和外部链接；不写模型自己的建议口吻，直接写成读者笔记正文。
                """, user: payload, jsonOutput: true, maxOutputTokens: 800)
    }

    func applyNoteReview(_ report: NoteReviewReport) async throws -> Int {
        var changed = 0
        for revision in report.revisions.prefix(8) {
            guard let index = state.readingNotes.firstIndex(where: { $0.id == revision.noteID }),
                state.readingNotes[index].deletedAt == nil,
                revision.markdown.count <= 20_000,
                !revision.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                revision.modifiedAt == nil
                    || abs(revision.modifiedAt!.timeIntervalSince(state.readingNotes[index].modifiedAt)) < 0.001
            else { continue }
            let sources = ChatSourceVersions()
            var note = state.readingNotes[index]
            guard Self.isSmallNoteRevision(from: note.markdown, to: revision.markdown) else { continue }
            if note.applyAIRevision(revision.markdown, sources: sources) {
                changed += 1
                state.readingNotes[index] = note
            }
        }
        if changed > 0, !(await save()) {
            throw ReaderError.message("笔记修订未能保存。")
        }
        return changed
    }

    /// A silent pass may add or correct a clause, but it must not rewrite the reader's note.
    /// Append-only edits are allowed; otherwise require substantial shared prefix/suffix and a
    /// bounded length change.
    static func isSmallNoteRevision(from old: String, to new: String) -> Bool {
        guard old != new, !new.isEmpty else { return false }
        let oldCount = old.count
        let newCount = new.count
        // Appending a bounded clarification is always a local edit; a replacement must stay close.
        if new.contains(old) { return newCount <= oldCount + 400 }
        guard newCount >= max(1, oldCount * 7 / 10), newCount <= max(oldCount, 1) * 14 / 10 else {
            return false
        }
        let oldChars = Array(old)
        let newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
            oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix]
        {
            suffix += 1
        }
        let shared = prefix + suffix
        let changedFraction = 1 - Double(shared) / Double(max(oldCount, newCount))
        return changedFraction <= 0.30
    }
}
