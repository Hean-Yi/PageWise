import Foundation
import SwiftSoup

/// Accessed exclusively by its owning HTMLReadingStore actor.
final class HTMLVerifiedSections {
    private struct FileIdentity: Equatable {
        let url: URL
        let paperID: UUID
        let size: Int
        let modified: Date?
        let inode: UInt64?
    }

    private enum Lookup {
        case indexed(HTMLSectionIndex)
        case legacy([String: Element])
    }

    private var oldEdition: (FileIdentity, Lookup)?

    func elements(at url: URL, paperID: UUID, artifact: HTMLReadingArtifact, positions: [Int]) throws -> [Element] {
        let lookup: Lookup
        if let index = artifact.sectionIndex {
            oldEdition = nil
            lookup = .indexed(index)
        } else {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let identity = FileIdentity(
                url: url, paperID: paperID, size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                modified: attributes[.modificationDate] as? Date,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
            if let oldEdition, oldEdition.0 == identity {
                lookup = oldEdition.1
            } else if let index = try? HTMLSectionIndex.recover(
                from: url, paperID: paperID, sections: artifact.sections)
            {
                lookup = .indexed(index)
                oldEdition = (identity, lookup)
            } else {
                let document = try SwiftSoup.parse(String(contentsOf: url, encoding: .utf8))
                guard let body = document.body(), try body.attr("data-paper-id") == paperID.uuidString,
                    let reader = try document.getElementById("reader")
                else { throw HTMLSectionIndex.invalidDocument }
                var sections: [String: Element] = [:]
                for element in reader.children() where element.tagName() == "section" {
                    let key = try element.attr("data-key")
                    guard sections.updateValue(element, forKey: key) == nil else {
                        throw HTMLSectionIndex.invalidDocument
                    }
                }
                lookup = .legacy(sections)
                // Large pre-index documents with nonstandard markup are only kept for this request.
                oldEdition = identity.size <= 8 * 1024 * 1024 ? (identity, lookup) : nil
            }
        }

        switch lookup {
        case .indexed(let index):
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            try index.validate(file: file, paperID: paperID, count: artifact.sections.count)
            return try positions.map { position in
                try Task.checkCancellation()
                let html = try index.read(position..<(position + 1), file: file)
                let fragment = try SwiftSoup.parseBodyFragment(html)
                guard let children = fragment.body()?.children(), children.count == 1, let element = children.first(),
                    element.tagName() == "section",
                    try element.attr("data-key") == artifact.sections[position].id.uuidString
                else { throw HTMLSectionIndex.invalidDocument }
                return element
            }
        case .legacy(let sections):
            return try positions.map { position in
                guard let element = sections[artifact.sections[position].id.uuidString] else {
                    throw HTMLSectionIndex.invalidDocument
                }
                return element
            }
        }
    }
}
