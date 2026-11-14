import Foundation
import PaperReaderKit

extension ReaderModel {
    @discardableResult public func createShelf(name: String) async -> UUID? {
        do {
            let shelf = try Shelf(name: name)
            return await save(shelfChange: .create(shelf)) ? shelf.id : nil
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    @discardableResult public func renameShelf(_ id: UUID, name: String) async -> Bool {
        await save(shelfChange: .rename(id, name))
    }

    @discardableResult public func deleteShelf(_ id: UUID) async -> Bool {
        await save(shelfChange: .delete(id))
    }

    @discardableResult public func movePaper(_ paperID: UUID, to shelfID: UUID?) async -> Bool {
        await save(shelfChange: .move(paperID: paperID, shelfID: shelfID))
    }
}
