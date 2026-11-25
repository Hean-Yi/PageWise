import Foundation
import PaperReaderKit

extension LibraryAgent {
    func organize(_ operation: AgentLibraryOperation, onSubject: @MainActor (String) -> Void) async throws
        -> AgentToolOutcome
    {
        switch operation {
        case .list(let scope, let shelf, let offset):
            return try listLibrary(scope, shelf: shelf, offset: offset)
        case .createShelf(let rawName):
            let shelf = try Shelf(name: rawName)
            onSubject(shelf.name)
            let existing = reader.state.shelves.filter {
                $0.name.localizedCaseInsensitiveCompare(shelf.name) == .orderedSame
            }
            guard existing.count <= 1 else { throw ReaderError.message("有多个同名书架，请先查看书架再确认目标。") }
            let id: UUID
            if let found = existing.first {
                id = found.id
            } else {
                guard let created = await reader.createShelf(name: shelf.name) else { throw saveFailure }
                id = created
            }
            shelfRegistry[id] = reader.state.shelves.first { $0.id == id }?.name
            return receipt(["shelf_id": id.uuidString], message: existing.isEmpty ? "已创建书架。" : "已找到同名书架。")
        case .renameShelf(let id, let rawName):
            let shelf = try registeredShelf(id)
            let name = try Shelf(name: rawName).name
            onSubject(shelf.name + " → " + name)
            guard
                !reader.state.shelves.contains(where: {
                    $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                })
            else {
                throw ReaderError.message("已有同名书架，请选择其他名称。")
            }
            guard await reader.renameShelf(id, name: name) else { throw saveFailure }
            shelfRegistry[id] = name
            return receipt(["shelf_id": id.uuidString], message: "已重命名书架。")
        case .movePapers(let ids, let destination):
            for id in ids { _ = try registeredPaper(id.uuidString, page: nil) }
            let name = try destination.map { try registeredShelf($0).name } ?? "未分类论文"
            onSubject("\(ids.count) 篇 → \(name)")
            guard await reader.movePapers(ids, to: destination) else { throw saveFailure }
            return receipt(["count": ids.count], message: "已归类 \(ids.count) 篇论文。")
        case .prepareDeletePaper(let id):
            let paper = try registeredPaper(id.uuidString, page: nil)
            var card = AgentCard(kind: .localPaper, title: paper.title)
            card.removal = .paper(id)
            card.removalGeneration = reader.lastPaperDeletion[id]
            onSubject(card.displayTitle)
            return receipt(["status": "awaiting_confirmation"], message: "请核对下方论文，点击「删除论文」并在弹窗确认后永久删除。", card: card)
        case .prepareDeleteShelf(let id):
            let shelf = try registeredShelf(id)
            var card = AgentCard(kind: .localPaper, title: shelf.name)
            card.removal = .shelf(id, members: members(of: id))
            onSubject(card.displayTitle)
            return receipt(["status": "awaiting_confirmation"], message: "请核对下方书架，确认后其中的论文会回到未分类。", card: card)
        case .prepareLocalImport(let target):
            let name = try target.map { try registeredShelf($0).name } ?? "未分类论文"
            var card = AgentCard(kind: .localPaper, title: name)
            card.localImportDestination = target.map(AgentCard.ImportDestination.shelf) ?? .unfiled
            onSubject(name)
            return receipt(["status": "awaiting_file_selection"], message: "选择本地 PDF 后即可导入目标书架。", card: card)
        }
    }

    private var saveFailure: ReaderError { .message(reader.message ?? "书库更改未能保存。") }

    private func registeredShelf(_ id: UUID) throws -> Shelf {
        guard let name = shelfRegistry[id], let shelf = reader.state.shelves.first(where: { $0.id == id }),
            shelf.name == name
        else {
            throw ReaderError.message("请先用 list_library 核对书架和当前名称。")
        }
        return shelf
    }

    private func members(of shelf: UUID) -> Set<UUID> {
        Set(reader.state.paperShelfIDs.compactMap { $0.value == shelf ? UUID(uuidString: $0.key) : nil })
    }

    func canConfirmRemoval(_ card: AgentCard) -> Bool {
        guard !card.removalCompleted, !confirmingRemovals.contains(card.id) else { return false }
        switch card.removal {
        case .paper(let id):
            return reader.lastPaperDeletion[id] == card.removalGeneration
                && reader.state.papers.contains { $0.id == id && $0.title == card.title }
        case .shelf(let id, let expected):
            return reader.state.shelves.contains { $0.id == id && $0.name == card.title } && members(of: id) == expected
        case nil: return false
        }
    }

    @discardableResult func confirmRemoval(cardID: UUID) async -> Bool {
        guard
            let turn = turns.last(where: { $0.presentedResults.contains { $0.id == cardID && $0.purpose == .removal } }
            ),
            let card = turn.cards.first(where: { $0.id == cardID }), canConfirmRemoval(card)
        else { return false }
        confirmingRemovals.insert(cardID)
        defer { confirmingRemovals.remove(cardID) }
        let saved: Bool
        let text: String
        switch card.removal {
        case .paper(let id):
            saved = await reader.deletePaper(id)
            text = "已永久删除《\(card.displayTitle)》。"
        case .shelf(let id, let members):
            saved = await reader.deleteShelf(id, expectedName: card.title, members: members)
            text = "已移除书架「\(card.title)」，其中论文已归入未分类。"
        case nil: return false
        }
        guard saved else { return false }
        updateTurn(turn.id) { turn in
            if let row = turn.cards.firstIndex(where: { $0.id == cardID }) { turn.cards[row].removalCompleted = true }
            if turn.cards.filter({ $0.removal != nil }).allSatisfy(\.removalCompleted) {
                turn.answer = turn.cards.filter { $0.removal != nil }.count == 1 ? text : "已完成所选移除操作。"
            }
        }
        return true
    }

    func importLocalPDFs(_ urls: [URL], cardID: UUID) async -> [UUID] {
        guard
            let turn = turns.last(where: {
                $0.presentedResults.contains { $0.id == cardID && $0.purpose == .localImport }
            }),
            let card = turn.cards.first(where: { $0.id == cardID }), let target = card.localImportDestination,
            card.importState != .importing, card.importState != .imported, !urls.isEmpty, urls.allSatisfy(\.isFileURL)
        else { return [] }
        let shelfID: UUID?
        switch target {
        case .shelf(let id):
            guard reader.state.shelves.contains(where: { $0.id == id && $0.name == card.title }) else {
                reader.message = "目标书架已变化，请重新选择。"
                return []
            }
            shelfID = id
        case .unfiled: shelfID = nil
        }
        let session = sessionID
        updateTurn(turn.id) { entry in
            guard let index = entry.cards.firstIndex(where: { $0.id == cardID }) else { return }
            entry.cards[index].importState = .importing
            entry.cards[index].importError = nil
        }
        let ids = await reader.importURLs(urls, selectAfterImport: false, shelfID: shelfID, moveDuplicateToShelf: true)
        guard session == sessionID else { return ids }
        paperRegistry.formUnion(ids)
        let complete = ids.count == urls.count
        updateTurn(turn.id) { entry in
            guard let index = entry.cards.firstIndex(where: { $0.id == cardID }) else { return }
            entry.cards[index].importState = complete ? .imported : .failed
            entry.cards[index].importError = complete ? nil : "还可重新选取未导入的 PDF。"
            entry.answer =
                complete
                ? "已将 \(ids.count) 份所选文件导入「\(card.title)」。"
                : "已导入 \(ids.count)/\(urls.count) 份文件，可重新选择未导入的 PDF。"
        }
        return ids
    }

    private func receipt(_ fields: [String: Any], message: String, card: AgentCard? = nil) -> AgentToolOutcome {
        var data = fields
        data["ok"] = true
        data["message"] = message
        let bytes = try? JSONSerialization.data(withJSONObject: data)
        let content = bytes.flatMap {
            $0.count <= limits.maxToolResultBytes ? String(decoding: $0, as: UTF8.self) : nil
        }
        return AgentToolOutcome(
            content: content ?? #"{"ok":true}"#, cards: card.map { [$0] } ?? [], truncated: content == nil,
            message: message)
    }

    private func listLibrary(_ scope: AgentLibraryScope, shelf: UUID?, offset: Int) throws -> AgentToolOutcome {
        let state = reader.state
        let limit = min(50, max(1, limits.maxResults))
        var rows: [CatalogRow] = []
        let total: Int
        switch scope {
        case .shelves:
            let counts = state.paperShelfIDs.values.reduce(into: [UUID: Int]()) { $0[$1, default: 0] += 1 }
            total = state.shelves.count
            rows = state.shelves.dropFirst(offset).prefix(limit).map {
                CatalogRow(shelfID: $0.id, title: $0.name, paperCount: counts[$0.id, default: 0])
            }
        case .shelf, .papers, .unfiled:
            if let shelf { _ = try registeredShelf(shelf) }
            let papers = scope == .papers ? state.papers : state.papers.filter { state.shelfID(for: $0.id) == shelf }
            total = papers.count
            rows = papers.dropFirst(offset).prefix(limit).map {
                CatalogRow(paperID: $0.id, shelfID: state.shelfID(for: $0.id), title: String($0.title.prefix(300)))
            }
        }
        while true {
            let more = offset + rows.count < total
            let page = CatalogPage(results: rows, total: total, nextOffset: more ? offset + rows.count : nil)
            let bytes = try JSONEncoder().encode(page)
            if bytes.count <= limits.maxToolResultBytes, !rows.isEmpty || !more {
                if scope == .shelves {
                    for shelf in state.shelves.dropFirst(offset).prefix(rows.count) {
                        shelfRegistry[shelf.id] = shelf.name
                    }
                } else {
                    paperRegistry.formUnion(rows.compactMap(\.paperID))
                }
                return AgentToolOutcome(
                    content: String(decoding: bytes, as: UTF8.self), cards: [], truncated: more,
                    message: "已列出 \(rows.count) 项，共 \(total) 项。")
            }
            guard !rows.isEmpty else { throw ReaderError.message("书库清单超过单次结果容量。") }
            rows.removeLast()
        }
    }
}

private struct CatalogRow: Encodable {
    var paperID: UUID?
    var shelfID: UUID?
    var title: String
    var paperCount: Int?
    enum CodingKeys: String, CodingKey {
        case paperID = "paper_id"
        case shelfID = "shelf_id"
        case title
        case paperCount = "paper_count"
    }
}

private struct CatalogPage: Encodable {
    let ok = true
    let results: [CatalogRow]
    let total: Int
    let nextOffset: Int?
    enum CodingKeys: String, CodingKey {
        case ok, results, total
        case nextOffset = "next_offset"
    }
}
