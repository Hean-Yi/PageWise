import Foundation

/// Startup-only cleanup: all committed page paths (including legacy annotated previews) are retained.
public enum ReflowArtifactCleanup {
    public static func removeUncommittedFiles(in root: URL, papers: [Paper]) throws {
        let manager = FileManager.default
        let papersDirectory = root.appendingPathComponent("Papers", isDirectory: true)
        if manager.fileExists(atPath: papersDirectory.path) {
            for url in try manager.contentsOfDirectory(
                at: papersDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            {
                if url.lastPathComponent.hasPrefix(".import-"),
                    UUID(uuidString: String(url.lastPathComponent.dropFirst(8))) != nil,
                    try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
                {
                    try manager.removeItem(at: url)
                }
            }
        }
        for paper in papers {
            try HTMLReadingStore.cleanup(root: root, paper: paper)
            let directory = root.appendingPathComponent("Papers/\(paper.id.uuidString)", isDirectory: true)
            let referenced = Set(
                (paper.previewPages + paper.translatedPages + (paper.retainedReadings ?? []).flatMap(\.pages)).map(
                    \.relativePath))
            for folder in ["preview", "translated"] {
                let location = directory.appendingPathComponent(folder, isDirectory: true)
                guard manager.fileExists(atPath: location.path) else { continue }
                for url in try manager.contentsOfDirectory(
                    at: location, includingPropertiesForKeys: [.isSymbolicLinkKey])
                {
                    guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                    let relative = "Papers/\(paper.id.uuidString)/\(folder)/\(url.lastPathComponent)"
                    if referenced.contains(relative) { continue }
                    let name = url.lastPathComponent
                    let staging = name.hasPrefix(".render-") && UUID(uuidString: String(name.dropFirst(8))) != nil
                    let generated =
                        name.range(
                            of:
                                #"^(?:(?:html-|source-)[0-9A-Fa-f-]{36}|(?:text|[0-9A-Fa-f-]{36})-[0-9A-Fa-f-]{36}-[0-9]{4,})\.pdf$"#,
                            options: .regularExpression) != nil
                    if staging || generated { try manager.removeItem(at: url) }
                }
            }
        }
    }
}
