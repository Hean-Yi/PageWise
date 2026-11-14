import Foundation

public struct Shelf: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public private(set) var name: String

    public init(id: UUID = UUID(), name: String) throws {
        self.id = id
        self.name = try Self.validatedName(name)
    }

    public mutating func rename(_ name: String) throws { self.name = try Self.validatedName(name) }

    private static func validatedName(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60,
            !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw ReaderError.message("书架名称须为 1–60 个字符，且不能包含换行。") }
        return clean
    }
}

public enum ShelfChange: Sendable {
    case create(Shelf)
    case rename(UUID, String)
    case delete(UUID)
    case move(paperID: UUID, shelfID: UUID?)
}

extension LibraryState {
    public func shelfID(for paperID: UUID) -> UUID? { paperShelfIDs[paperID.uuidString] }

    public mutating func apply(_ change: ShelfChange) throws {
        switch change {
        case .create(let shelf):
            guard !shelves.contains(where: { $0.id == shelf.id }) else {
                throw ReaderError.message("书架已存在。")
            }
            shelves.append(shelf)
        case .rename(let id, let name):
            guard let index = shelves.firstIndex(where: { $0.id == id }) else {
                throw ReaderError.message("书架不存在。")
            }
            try shelves[index].rename(name)
        case .delete(let id):
            guard shelves.contains(where: { $0.id == id }) else { throw ReaderError.message("书架不存在。") }
            shelves.removeAll { $0.id == id }
            paperShelfIDs = paperShelfIDs.filter { $0.value != id }
        case .move(let paperID, let shelfID):
            guard papers.contains(where: { $0.id == paperID }),
                shelfID == nil || shelves.contains(where: { $0.id == shelfID })
            else { throw ReaderError.message("论文或书架不存在，未移动。") }
            paperShelfIDs[paperID.uuidString] = shelfID
        }
        try validateShelves()
    }

    public func validateShelves() throws {
        guard Set(shelves.map(\.id)).count == shelves.count else { throw ReaderError.message("书架 ID 重复。") }
        for shelf in shelves { _ = try Shelf(id: shelf.id, name: shelf.name) }
        let paperIDs = Set(papers.map { $0.id.uuidString })
        let shelfIDs = Set(shelves.map(\.id))
        guard paperShelfIDs.allSatisfy({ paperIDs.contains($0.key) && shelfIDs.contains($0.value) }) else {
            throw ReaderError.message("书架归属包含无效记录，原资料已保留。")
        }
    }
}
