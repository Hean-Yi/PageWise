import CryptoKit
import Foundation

/// A note stores its own authorized destinations. The URL carries no path, excerpt, page or paper identifier.
public struct LocalPassageCitation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let paperID: UUID
    public let digest: String
    public let contentVersion: String
    public let anchors: [NoteAnchor]
    public let quote: String

    public init(paperID: UUID, digest: String, contentVersion: String, anchors: [NoteAnchor], quote: String) {
        self.paperID = paperID
        self.digest = digest
        self.contentVersion = contentVersion
        self.anchors = anchors
        self.quote = quote
        // A retried model response that cites the same passage yields the same Markdown and note.
        let values =
            [paperID.uuidString, digest, contentVersion, quote]
            + anchors.flatMap {
                [$0.key, $0.target, String($0.start), String($0.end), $0.text]
            }
        var hash = SHA256()
        for string in values {
            hash.update(data: Data("\(string.utf8.count):".utf8))
            hash.update(data: Data(string.utf8))
        }
        id = UUID(uuid: Array(hash.finalize().prefix(16)).withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
    }

    public var url: URL { URL(string: "paperreader://passage/" + id.uuidString)! }

    public static func id(from url: URL) -> UUID? {
        let prefix = "paperreader://passage/"
        let raw = url.absoluteString
        guard raw.hasPrefix(prefix), let id = UUID(uuidString: String(raw.dropFirst(prefix.count))),
            raw.lowercased() == prefix + id.uuidString.lowercased()
        else { return nil }
        return id
    }

    public func markdown(label: String) -> String {
        let plain = String(label.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
        let escaped = (plain.isEmpty ? "原文" : plain).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(url.absoluteString))"
    }
}
