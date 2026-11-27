import CryptoKit
import Foundation

public struct NoteMergeResult: Sendable {
    public var text: String
    public var baseline: String
}

public enum NoteMerger {
    public static func merge(existing: String, body: String, paperID: UUID, baseline: String?) throws -> NoteMergeResult
    {
        let start = "<!-- paperreader:\(paperID.uuidString):begin -->"
        let end = "<!-- paperreader:\(paperID.uuidString):end -->"
        guard !body.contains(start), !body.contains(end) else {
            throw ReaderError.message("笔记正文含有当前笔记的管理标记，请移除标记后再保存。")
        }
        let managed = "\(start)\n\(body)\n\(end)"
        let digest = hash(managed)
        let startCount = existing.components(separatedBy: start).count - 1
        let endCount = existing.components(separatedBy: end).count - 1
        if startCount == 0 && endCount == 0 {
            guard baseline == nil else { throw ReaderError.message("笔记管理标记已被修改；请保留现有笔记并另存。") }
            return NoteMergeResult(text: existing + (existing.isEmpty ? "" : "\n\n") + managed + "\n", baseline: digest)
        }
        guard startCount == 1, endCount == 1, let a = existing.range(of: start), let b = existing.range(of: end),
            a.lowerBound < b.lowerBound
        else {
            throw ReaderError.message("笔记中存在重复或损坏的管理标记，未覆盖文件。")
        }
        let range = a.lowerBound..<b.upperBound
        guard let baseline, hash(String(existing[range])) == baseline else {
            throw ReaderError.message("Obsidian 中的生成内容已被修改。本次保存已停止，原笔记保持不变。")
        }
        return NoteMergeResult(text: existing.replacingCharacters(in: range, with: managed), baseline: digest)
    }

    public static func managedHash(_ existing: String, paperID: UUID) -> String? {
        let start = "<!-- paperreader:\(paperID.uuidString):begin -->"
        let end = "<!-- paperreader:\(paperID.uuidString):end -->"
        guard existing.components(separatedBy: start).count == 2,
            existing.components(separatedBy: end).count == 2,
            let a = existing.range(of: start), let b = existing.range(of: end), a.lowerBound < b.lowerBound
        else { return nil }
        return hash(String(existing[a.lowerBound..<b.upperBound]))
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public actor VaultService {
    private let bookmarkURL: URL
    private let recoveryDirectory: URL
    public init(root: URL) {
        bookmarkURL = root.appendingPathComponent("vault.bookmark")
        recoveryDirectory = root.appendingPathComponent("NoteBindings")
    }
    private struct BindingRecord: Codable {
        var filename: String
        var baseline: String
        var discussion: String
        var summary: String
        var vaultID: String?
        var pending: Bool?
    }

    private func recordURL(for id: UUID) -> URL { recoveryDirectory.appendingPathComponent(id.uuidString + ".json") }

    private func bindings(for id: UUID) throws -> [BindingRecord] {
        let file = recordURL(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        if let records = try? decoder.decode([BindingRecord].self, from: data) { return records }
        // Older versions stored a single binding without a vault identifier.
        return [try decoder.decode(BindingRecord.self, from: data)]
    }

    private func bindings(in records: [BindingRecord], vaultID: String, paper: Paper) -> [BindingRecord] {
        if records.isEmpty, let filename = paper.notePath, let baseline = paper.noteBaseline {
            // Libraries predating the recovery journal can prove ownership with the stored file hash.
            return [
                BindingRecord(
                    filename: filename, baseline: baseline, discussion: paper.savedDiscussion, summary: paper.summary)
            ]
        }
        return records.filter { $0.vaultID == vaultID || $0.vaultID == nil }
    }

    public func recover(_ paper: Paper) throws -> Paper { try exportContext(for: paper).paper }

    public func exportContext(for paper: Paper) throws -> (destination: URL, paper: Paper) {
        let folder = try directory()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let records = bindings(
            in: try bindings(for: paper.id), vaultID: NoteMerger.hash(folder.standardizedFileURL.path), paper: paper)
        var recovered = paper
        recovered.notePath = nil
        recovered.noteBaseline = nil
        recovered.savedDiscussion = ""
        guard let filename = records.first?.filename, filename == URL(fileURLWithPath: filename).lastPathComponent
        else {
            return (folder, recovered)
        }
        let target = folder.appendingPathComponent(filename)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil,
            let text = try? String(contentsOf: target, encoding: .utf8),
            let baseline = NoteMerger.managedHash(text, paperID: paper.id),
            let record = records.first(where: { $0.filename == filename && $0.baseline == baseline })
        else { return (folder, recovered) }
        recovered.notePath = filename
        recovered.noteBaseline = baseline
        recovered.savedDiscussion = record.discussion
        if recovered.summary.isEmpty { recovered.summary = record.summary }
        return (folder, recovered)
    }

    public func select(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
            let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
            let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        #endif
        let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        try data.write(to: bookmarkURL, options: .atomic)
    }

    public func directory() throws -> URL {
        guard FileManager.default.fileExists(atPath: bookmarkURL.path) else {
            throw ReaderError.message("请先在设置中选择 Obsidian 笔记目录。")
        }
        let data = try Data(contentsOf: bookmarkURL)
        var stale = false
        #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
            let options: URL.BookmarkResolutionOptions = []
        #endif
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw ReaderError.message("笔记目录授权已过期，请重新选择目录。") }
        return url
    }

    public func notes() throws -> [Evidence] {
        let folder = try directory()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var result: [Evidence] = []
        for case let file as URL in enumerator {
            guard result.count < 200 else { break }
            guard file.pathExtension.lowercased() == "md",
                let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 256_000,
                let content = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            result.append(
                Evidence(
                    id: "", title: file.deletingPathExtension().lastPathComponent,
                    text: String(content.prefix(8000)), notePath: file.path))
        }
        return result
    }

    public func exportInk(paperID: UUID, root: URL) throws -> [String] {
        let source = root.appendingPathComponent("Papers/\(paperID.uuidString)/Ink")
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        let folder = try directory()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let assets = folder.appendingPathComponent("PaperReader-Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { file in
            let data = try Data(contentsOf: file)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let name =
                "\(paperID.uuidString)-\(file.deletingPathExtension().lastPathComponent)-\(digest.prefix(12)).png"
            let destination = assets.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .withoutOverwriting)
            }
            return "![[PaperReader-Attachments/\(name)]]"
        }
    }

    public func saveReadingDocument(paper: Paper, body: String, root: URL, destination: URL) throws -> (
        path: String, baseline: String
    ) {
        try Task.checkCancellation()
        guard try directory().standardizedFileURL.path == destination.standardizedFileURL.path else {
            throw ReaderError.message("Obsidian 目录已变更，请在新目录中重新保存。")
        }
        let ink = try exportInk(paperID: paper.id, root: root)
        let document = ink.isEmpty ? body : body + "\n\n## 手写批注\n\n" + ink.joined(separator: "\n\n")
        try Task.checkCancellation()
        return try save(paper: paper, body: document)
    }

    private static func initialDocument(for paper: Paper) -> String {
        let safeTitle = paper.title.replacingOccurrences(of: "\n", with: " ")
        let escapedTitle = safeTitle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "\"", with: "\\\"")
        var frontmatter = [
            "---",
            "title: \"\(escapedTitle)\"",
            "paper_id: \"\(paper.id.uuidString)\"",
            "pagewise_url: \"pagewise://open?paper=\(paper.id.uuidString)\"",
        ]
        if let source = paper.sourceURL, !source.isEmpty {
            let escapedSource = source.replacingOccurrences(of: "\"", with: "\\\"")
            frontmatter.append("source: \"\(escapedSource)\"")
        }
        frontmatter.append("---")
        return frontmatter.joined(separator: "\n") + "\n\n# \(safeTitle)\n\n## 我的笔记\n\n"
    }

    private static func titleStem(_ title: String) -> String {
        let separators = CharacterSet(charactersIn: #"/\:*?"<>|[]#^"#)
            .union(.controlCharacters).union(.whitespacesAndNewlines)
        let text = title.precomposedStringWithCanonicalMapping.components(separatedBy: separators)
            .filter { !$0.isEmpty }.joined(separator: " ")
        var stem = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= 180 else { break }
            stem.append(character)
            bytes += size
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return stem.isEmpty ? "阅读笔记" : stem
    }

    public func save(paper: Paper, body: String) throws -> (path: String, baseline: String) {
        let folder = try directory()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let journal = recordURL(for: paper.id)
        let records = try bindings(for: paper.id)
        let vaultID = NoteMerger.hash(folder.standardizedFileURL.path)
        let local = bindings(in: records, vaultID: vaultID, paper: paper)
        let boundName = local.first?.filename ?? (records.isEmpty ? paper.notePath : nil)
        let stem = Self.titleStem(paper.title)
        let suffix = String(paper.id.uuidString.prefix(8))
        var attempt = 0
        while true {
            let filename: String
            if let boundName {
                filename = boundName
            } else {
                switch attempt {
                case 0: filename = "\(stem).md"
                case 1: filename = "\(stem) — \(suffix).md"
                default: filename = "\(stem) — \(suffix)-\(attempt).md"
                }
            }
            guard !filename.isEmpty, filename != ".", filename != "..",
                filename == URL(fileURLWithPath: filename).lastPathComponent
            else { throw ReaderError.message("笔记路径无效。") }

            let file = folder.appendingPathComponent(filename)
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<String?, Error>?
            coordinator.coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { target in
                result = Result {
                    let manager = FileManager.default
                    let isLink = (try? manager.destinationOfSymbolicLink(atPath: target.path)) != nil
                    let exists = manager.fileExists(atPath: target.path)
                    if boundName == nil && (exists || isLink) { return nil }
                    guard !isLink else { throw ReaderError.message("笔记已被替换为符号链接，请检查笔记目录。") }
                    if !exists, local.contains(where: { $0.pending != true }) {
                        throw ReaderError.message("原 Obsidian 笔记已移动或删除，请检查笔记目录。")
                    }
                    let existing =
                        exists
                        ? try String(contentsOf: target, encoding: .utf8)
                        : Self.initialDocument(for: paper)
                    let currentHash = NoteMerger.managedHash(existing, paperID: paper.id)
                    let prior = local.first { $0.filename == filename && $0.baseline == currentHash }
                    guard !exists || prior != nil else {
                        throw ReaderError.message("Obsidian 中的生成内容已被修改。本次保存已停止，原笔记保持不变。")
                    }
                    let merged = try NoteMerger.merge(
                        existing: existing, body: body, paperID: paper.id, baseline: prior?.baseline)
                    try manager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
                    let others = records.filter { $0.vaultID != nil && $0.vaultID != vaultID }
                    var next = BindingRecord(
                        filename: filename, baseline: merged.baseline, discussion: paper.savedDiscussion,
                        summary: paper.summary, vaultID: vaultID, pending: true)
                    // Either content can be on disk after interruption. Both baselines belong to this vault.
                    var pending = others + [next]
                    if var prior {
                        prior.vaultID = vaultID
                        prior.pending = nil
                        pending.append(prior)
                    }
                    try JSONEncoder().encode(pending).write(to: journal, options: .atomic)
                    let data = Data(merged.text.utf8)
                    if exists {
                        try data.write(to: target, options: .atomic)
                    } else {
                        let staging = try manager.url(
                            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
                        defer { try? manager.removeItem(at: staging) }
                        let temporary = staging.appendingPathComponent("note.md")
                        try data.write(to: temporary)
                        // A same-volume move publishes the complete file and refuses an occupied destination.
                        try manager.moveItem(at: temporary, to: target)
                    }
                    next.pending = nil
                    try JSONEncoder().encode(others + [next]).write(to: journal, options: .atomic)
                    return merged.baseline
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw ReaderError.message("无法协调笔记写入。") }
            if let baseline = try result.get() { return (filename, baseline) }
            attempt += 1
        }
    }
}
