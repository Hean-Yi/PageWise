import CryptoKit
import Foundation

extension LibraryStore {
    // Write the intent before SQLite. On restart the committed snapshot decides whether to discard
    // the intent (the paper still exists) or finish unlinking its managed files.
    func stageFileRemoval(_ paper: Paper) throws {
        try Data(paper.digest.utf8).write(to: removalMarker(paper.id), options: .atomic)
    }

    public func recoverFileRemovals(keeping papers: [Paper]) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for url in urls where url.lastPathComponent.hasPrefix(Self.markerPrefix) {
            let suffix = url.lastPathComponent.dropFirst(Self.markerPrefix.count)
            guard let id = UUID(uuidString: String(suffix)),
                url.lastPathComponent == removalMarker(id).lastPathComponent,
                try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { continue }
            if papers.contains(where: { $0.id == id }) {
                try FileManager.default.removeItem(at: url)
            } else {
                let digest = try String(contentsOf: url, encoding: .utf8)
                try finishFileRemoval(id: id, digest: digest, keepDigest: papers.contains { $0.digest == digest })
            }
        }
    }

    public func finishFileRemoval(id: UUID, digest: String, keepDigest: Bool, retireMarker: Bool = true) throws {
        try removeManagedPath(["Papers", id.uuidString])
        if !keepDigest {
            let key = SHA256.hash(data: Data(digest.utf8)).map { String(format: "%02x", $0) }.joined()
            try removeManagedPath(["PDFTranslations", key])
            try removeManagedPath(["PaperAbstracts", "v1", key])
        }
        if retireMarker { try removeManagedPath([removalMarker(id).lastPathComponent]) }
    }

    private static let markerPrefix = ".paper-removal-"

    private func removalMarker(_ id: UUID) -> URL {
        directory.appendingPathComponent(Self.markerPrefix + id.uuidString)
    }

    private func removeManagedPath(_ components: [String]) throws {
        var url = directory
        do {
            for component in components.dropLast() {
                url.appendPathComponent(component, isDirectory: true)
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw ReaderError.message("应用资料目录是符号链接，文件清理将在下次打开时重试。")
                }
            }
            try FileManager.default.removeItem(at: url.appendingPathComponent(components.last!))
        } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            return
        }
    }
}
