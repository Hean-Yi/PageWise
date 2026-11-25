import Foundation

/// Startup-only cleanup: all committed page paths (including legacy annotated previews) are retained.
public enum ReadingArtifactCleanup {
    public static func removeUncommittedFiles(in root: URL, papers: [Paper]) throws {
        let manager = FileManager.default
        let papersDirectory = root.appendingPathComponent("Papers", isDirectory: true)
        if manager.fileExists(atPath: papersDirectory.path) {
            guard try papersDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw ReaderError.message("论文目录是符号链接，已跳过文件清理。")
            }
            let referenced = Set(papers.map(\.id)).union(
                papers.compactMap { paper -> UUID? in
                    let path = paper.originalPath.split(separator: "/")
                    guard path.count >= 3, path[0] == "Papers" else { return nil }
                    return UUID(uuidString: String(path[1]))
                })
            for url in try manager.contentsOfDirectory(
                at: papersDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            {
                let name = url.lastPathComponent
                let staging = name.hasPrefix(".import-")
                guard let id = UUID(uuidString: staging ? String(name.dropFirst(8)) : name) else { continue }
                let marker = PendingPDFImport.marker(in: url, id: id)
                guard staging || manager.fileExists(atPath: marker.path) else { continue }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true, let lock = try ImportDirectoryLock(url)
                else { continue }
                try withExtendedLifetime(lock) {
                    if staging {
                        try manager.removeItem(at: url)
                    } else if manager.fileExists(atPath: marker.path) {
                        let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
                        try manager.removeItem(at: referenced.contains(id) ? marker : url)
                    }
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
