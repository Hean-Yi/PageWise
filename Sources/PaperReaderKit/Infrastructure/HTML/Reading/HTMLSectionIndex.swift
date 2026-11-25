import Darwin
import Foundation

extension HTMLSectionIndex {
    static let opening = "<!--paperreader-content-start-->"
    static let closing = "<!--paperreader-content-end--></main></body></html>"

    private static func paperMarker(_ id: UUID) -> Data {
        Data("<body data-paper-id=\"\(id.uuidString)\"><main id=\"reader\">\(opening)".utf8)
    }

    /// Called only on the first append to an edition saved before byte indexes were recorded.
    static func recover(from url: URL, paperID: UUID, sections: [PageArtifact]) throws -> Self {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let ending = Data(closing.utf8)
        guard let header = bytes.range(of: paperMarker(paperID)), bytes.suffix(ending.count) == ending
        else { throw invalidDocument }
        let limit = bytes.count - ending.count
        let start = header.upperBound
        guard start <= limit else { throw invalidDocument }
        var cursor = start
        var ends: [UInt64] = []
        for (i, section) in sections.enumerated() {
            let tag = Data("<section id='block-\(section.id.uuidString)'".utf8)
            guard let match = bytes.range(of: tag, in: cursor..<limit), i > 0 || match.lowerBound == start
            else { throw invalidDocument }
            if i > 0 { ends.append(UInt64(match.lowerBound)) }
            cursor = match.upperBound
        }
        if !sections.isEmpty { ends.append(UInt64(limit)) }
        guard !sections.isEmpty || start == limit else { throw invalidDocument }
        return .init(start: UInt64(start), ends: ends)
    }

    func validate(file: FileHandle, paperID: UUID, count: Int) throws {
        let marker = Self.paperMarker(paperID)
        let (length, overflow) = end.addingReportingOverflow(UInt64(Self.closing.utf8.count))
        guard !overflow, ends.count == count, start >= UInt64(marker.count), end >= start,
            try file.seekToEnd() == length
        else { throw Self.invalidDocument }
        try file.seek(toOffset: start - UInt64(marker.count))
        guard try file.read(upToCount: marker.count) == marker else { throw Self.invalidDocument }
        try file.seek(toOffset: end)
        guard try file.read(upToCount: Self.closing.utf8.count) == Data(Self.closing.utf8) else {
            throw Self.invalidDocument
        }
    }

    func read(_ sections: Range<Int>, file: FileHandle) throws -> String {
        guard sections.lowerBound >= 0, sections.upperBound <= ends.count else { throw Self.invalidDocument }
        if sections.isEmpty { return "" }
        let from = sections.lowerBound == 0 ? start : ends[sections.lowerBound - 1]
        let until = ends[sections.upperBound - 1]
        guard start <= from, from < until, until <= end, let length = Int(exactly: until - from) else {
            throw Self.invalidDocument
        }
        try file.seek(toOffset: from)
        guard let bytes = try file.read(upToCount: length), bytes.count == length,
            let html = String(data: bytes, encoding: .utf8)
        else { throw Self.invalidDocument }
        return html
    }

    /// APFS snapshots share old pages. A non-cloning volume uses the system's disk-to-disk copy.
    static func append(_ sections: Data, replacingTailAt offset: UInt64, from old: URL, to new: URL) throws {
        if clonefile(old.path, new.path, 0) != 0 {
            try FileManager.default.copyItem(at: old, to: new)
        }
        do {
            let file = try FileHandle(forWritingTo: new)
            defer { try? file.close() }
            try file.seek(toOffset: offset)
            try file.write(contentsOf: sections)
            try file.write(contentsOf: Data(closing.utf8))
        } catch {
            try? FileManager.default.removeItem(at: new)
            throw error
        }
    }

    static var invalidDocument: ReaderError { .message("已保存的阅读内容无法完整读取，未覆盖。") }
}
