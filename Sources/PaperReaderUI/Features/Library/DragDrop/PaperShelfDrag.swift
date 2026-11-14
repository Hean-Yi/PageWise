import PaperReaderKit
import SwiftUI
import UniformTypeIdentifiers

/// Uses a dedicated type so internal moves never compete with Finder PDF URLs.
enum PaperShelfDrag {
    static let typeIdentifier = "dev.paperreader.paper-reference"

    static func provider(_ paperID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(paperID.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func paperID(from data: Data) -> UUID? {
        guard data.count == 36, let value = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }

    @MainActor static func receive(
        _ providers: [NSItemProvider], model: ReaderModel, shelfID: UUID?
    ) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }
        guard !matching.isEmpty else { return false }
        ShelfDragDiagnostics.record("target-receive")
        for provider in matching {
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data, let id = paperID(from: data) else {
                    ShelfDragDiagnostics.record("target-invalid-data")
                    return
                }
                Task { @MainActor in
                    guard model.state.papers.contains(where: { $0.id == id }) else { return }
                    let saved = await model.movePaper(id, to: shelfID)
                    ShelfDragDiagnostics.record(saved ? "target-saved" : "target-save-failed")
                }
            }
        }
        return true
    }
}
