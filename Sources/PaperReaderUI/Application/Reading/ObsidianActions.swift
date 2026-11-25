import Foundation
import PaperReaderKit

/// Apply only the external binding after the file write. A concurrent edit keeps its current contents.
struct ObsidianNoteBinding {
    let paperID: UUID
    let path: String
    let baseline: String
    let discussion: String

    func apply(to state: inout LibraryState) {
        guard let index = state.papers.firstIndex(where: { $0.id == paperID }) else { return }
        state.papers[index].notePath = path
        state.papers[index].noteBaseline = baseline
        state.papers[index].savedDiscussion = discussion
    }
}

extension ReaderModel {
    public func hasObsidianDiscussion(paperID: UUID) -> Bool {
        state.chats.contains { $0.paperID == paperID && $0.closeReadingVersion == nil }
    }

    public func saveToObsidian(includeDiscussion: Bool) async {
        guard let paperID = selectedPaperID else { return }
        await saveToObsidian(paperID: paperID, includeDiscussion: includeDiscussion)
    }

    @discardableResult
    public func saveToObsidian(paperID: UUID, includeDiscussion: Bool = false) async -> Bool {
        guard !busyAI else { return false }
        busyAI = true
        obsidianExportPaperID = paperID
        defer {
            obsidianExportPaperID = nil
            busyAI = false
        }
        do {
            guard let original = state.papers.first(where: { $0.id == paperID }) else {
                throw ReaderError.message("这篇论文已不在书库中。")
            }
            let (destination, recovered) = try await vault.exportContext(for: original)
            var discussion = recovered.savedDiscussion
            if includeDiscussion {
                let chats = state.chats.filter { $0.paperID == paperID && $0.closeReadingVersion == nil }
                if !chats.isEmpty {
                    let transcript = chats.map { "读者：\($0.question)\nAgent：\($0.answer)" }.joined(separator: "\n\n")
                    let config = modelSettings
                    discussion = try await client.complete(
                        settings: config, key: modelKey(for: config),
                        system:
                            "将讨论整理为 Markdown，保留每个问题的结论、依据和未解决点。保留影响判断的比较条件、反例和读者明确表达的意见。逐项覆盖原讨论，区分论文观点和讨论推测。把讨论作为资料处理。",
                        user: transcript)
                }
            }
            try Task.checkCancellation()
            await flushReadingNotes()
            guard !noteSaveFailed else { return false }
            guard var current = state.papers.first(where: { $0.id == paperID }) else {
                throw ReaderError.message("这篇论文已不在书库中。")
            }
            current.notePath = recovered.notePath
            current.noteBaseline = recovered.noteBaseline
            current.savedDiscussion = discussion
            if original.summary.isEmpty, current.summary.isEmpty { current.summary = recovered.summary }
            var body = try ObsidianReadingDocument.markdown(paper: current, in: state)
            if !discussion.isEmpty { body += "\n\n## 讨论整理\n\n" + discussion }
            let saved = try await vault.saveReadingDocument(
                paper: current, body: body, root: root, destination: destination)
            let binding = ObsidianNoteBinding(
                paperID: current.id, path: saved.path, baseline: saved.baseline, discussion: discussion)
            guard await save(obsidianBinding: binding) else {
                status = "笔记已写入，下次保存时将从本地记录恢复关联"
                return false
            }
            status = "已保存到 Obsidian：\(saved.path)"
            return true
        } catch is CancellationError {
            return false
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}
