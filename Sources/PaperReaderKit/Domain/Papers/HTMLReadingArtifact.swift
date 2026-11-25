import Foundation

/// One committed HTML document, its required assets, and stable content anchors.
public struct HTMLReadingArtifact: Codable, Sendable, Equatable {
    /// Assigned on a rebuild that reuses the first block of another edition. Old manifests use their first section.
    public var editionID: UUID?
    public func readingNoteVersion(digest: String) -> String? {
        (editionID ?? sections.first?.id).map { digest + ":" + $0.uuidString }
    }

    // Missing in earlier editions. Its absence never changes a saved page or its anchors.
    var sectionIndex: HTMLSectionIndex?
    public var relativePath: String
    public var sections: [PageArtifact]
    public var assets: [String]
    public init(relativePath: String, sections: [PageArtifact], assets: [String]) {
        self.relativePath = relativePath
        self.sections = sections
        self.assets = assets
    }
}

/// UTF-8 boundaries in an immutable, standalone reading document. The DOM still owns selection offsets.
struct HTMLSectionIndex: Codable, Sendable, Equatable {
    let start: UInt64
    var ends: [UInt64]
    var end: UInt64 { ends.last ?? start }

}
