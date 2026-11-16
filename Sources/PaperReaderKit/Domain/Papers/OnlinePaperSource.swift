import Foundation

/// The original download is retained so a new reading version can be reproduced offline.
public struct OnlinePaperSource: Codable, Sendable, Equatable {
    public var candidateID: String
    public var archivePath: String?
    public var archiveDigest: String?
    public var notice: String?
    public init(candidateID: String, archivePath: String? = nil, archiveDigest: String? = nil, notice: String? = nil) {
        self.candidateID = candidateID
        self.archivePath = archivePath
        self.archiveDigest = archiveDigest
        self.notice = notice
    }
}

/// Ordinal in the deterministic, expanded source document; never a fabricated PDF page.
public struct TeXSourceAnchor: Codable, Sendable, Equatable {
    public var archiveDigest: String
    public var mainFile: String
    public var blockIndex: Int
    public var parserVersion: Int = 1
}
