import Foundation

/// One committed HTML document, its required assets, and stable content anchors.
public struct HTMLReadingArtifact: Codable, Sendable, Equatable {
    public var relativePath: String
    public var sections: [PageArtifact]
    public var assets: [String]
    public init(relativePath: String, sections: [PageArtifact], assets: [String]) {
        self.relativePath = relativePath
        self.sections = sections
        self.assets = assets
    }
}
