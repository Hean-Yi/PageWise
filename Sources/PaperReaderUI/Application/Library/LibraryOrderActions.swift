import Foundation
import PaperReaderKit

extension ReaderModel {
    @discardableResult public func selectLibrarySort(_ sort: LibrarySort) async -> Bool {
        await save(cancellable: true, orderChange: .select(sort))
    }

    @discardableResult public func arrangePapers(
        original: [UUID], reordered: [UUID], unfinishedFirst: Bool
    ) async -> Bool {
        await save(
            cancellable: true,
            orderChange: .arrange(original: original, reordered: reordered, unfinishedFirst: unfinishedFirst))
    }
}
