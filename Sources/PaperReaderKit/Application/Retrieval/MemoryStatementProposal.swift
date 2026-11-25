import Foundation

/// A silent, agent-generated statement that is not necessarily a question. It still needs an
/// exact reader or registered-note quote, so the library does not become a model scratchpad.
public struct MemoryStatementProposal: Sendable {
    public let item: MemoryItem

    public static func isEligible(_ item: MemoryItem, in state: LibraryState, excluding pending: Set<UUID>) -> Bool {
        guard !item.deleted, item.text.count <= 300,
            !state.memories.contains(where: {
                $0.id == item.id || ($0.sourceID == item.sourceID && $0.text == item.text)
            })
        else { return false }
        if let fingerprint = item.originalFingerprint, state.suppressedMemoryFingerprints.contains(fingerprint) {
            return false
        }
        let origins = ResearchMemoryOrigins(state: state, excluding: pending, for: [item])
        return origins.resolve(item) != nil
    }

    public init(statement: String, readerTurnID: UUID, readerMessage: String, quote: String) throws {
        let value = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...240).contains(value.count), (6...240).contains(evidence.count),
            readerMessage.contains(evidence), ResearchMemory.permitsAutomaticWrite(for: readerMessage),
            !ResearchQuestionProposal.isOperational(value)
        else { throw ReaderError.message("需要一个可核对来源的具体记忆陈述。") }
        item = MemoryItem(
            agentStatement: value, sourceID: readerTurnID, source: .reader(quote: evidence))
    }

    public init(statement: String, quote: String, registeredExcerpt: String, note: ReadingNote) throws {
        let value = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.deletedAt == nil, note.backgroundSources == nil,
            (6...240).contains(value.count), (6...240).contains(evidence.count),
            registeredExcerpt.contains(evidence),
            ReadingNoteMemoryIndex.searchableBody(note.markdown).contains(evidence),
            !ResearchQuestionProposal.isOperational(value)
        else { throw ReaderError.message("需要一个可核对来源的具体笔记陈述。") }
        item = MemoryItem(
            agentStatement: value, sourceID: note.id, source: .note(paperID: note.paperID, modifiedAt: note.modifiedAt))
    }
}
