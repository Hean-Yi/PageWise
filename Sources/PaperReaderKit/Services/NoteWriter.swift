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
    }
    public func recover(_ paper: Paper) throws -> Paper {
        let recordURL = recoveryDirectory.appendingPathComponent(paper.id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return paper }
        let record = try JSONDecoder().decode(BindingRecord.self, from: Data(contentsOf: recordURL))
        guard record.filename == URL(fileURLWithPath: record.filename).lastPathComponent else { return paper }
        let folder = try directory()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let target = folder.appendingPathComponent(record.filename)
        guard let text = try? String(contentsOf: target, encoding: .utf8),
            NoteMerger.managedHash(text, paperID: paper.id) == record.baseline
        else { return paper }
        var recovered = paper
        recovered.notePath = record.filename
        recovered.noteBaseline = record.baseline
        recovered.savedDiscussion = record.discussion
        if recovered.summary.isEmpty { recovered.summary = record.summary }
        return recovered
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

    public func save(paper: Paper, body: String) throws -> (path: String, baseline: String) {
        let folder = try directory()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let filename = paper.notePath ?? "PaperReader-\(paper.id.uuidString).md"
        guard filename == URL(fileURLWithPath: filename).lastPathComponent else { throw ReaderError.message("笔记路径无效。") }
        let file = folder.appendingPathComponent(filename)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<NoteMergeResult, Error>?
        coordinator.coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { target in
            result = Result {
                let exists = FileManager.default.fileExists(atPath: target.path)
                let existing =
                    exists
                    ? try String(contentsOf: target, encoding: .utf8)
                    : "# \(paper.title.replacingOccurrences(of: "\n", with: " "))\n\n## 我的笔记\n\n"
                let merged = try NoteMerger.merge(
                    existing: existing, body: body, paperID: paper.id, baseline: paper.noteBaseline)
                // Journal before the external write. Recovery only trusts it when the file's managed hash matches.
                try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
                let record = BindingRecord(
                    filename: filename, baseline: merged.baseline, discussion: paper.savedDiscussion,
                    summary: paper.summary)
                let recordURL = recoveryDirectory.appendingPathComponent(paper.id.uuidString + ".json")
                try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
                try Data(merged.text.utf8).write(to: target, options: .atomic)
                return merged
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ReaderError.message("无法协调笔记写入。") }
        return (filename, try result.get().baseline)
    }
}
