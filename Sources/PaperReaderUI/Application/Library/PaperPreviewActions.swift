import Foundation
import NaturalLanguage
import PaperReaderKit

extension ReaderModel {
    func prepareImportedAbstract(for id: UUID) async {
        guard let paper = state.papers.first(where: { $0.id == id }), !Task.isCancelled else { return }
        // A delayed or unreadable file can be retried on the next load without rolling back the import.
        try? await previewReader.prepare(paper: paper, root: root)
    }

    func backfillLibraryAbstracts() {
        guard !state.papers.isEmpty else { return }
        abstractBackfill?.cancel()
        abstractBackfill = Task(priority: .utility) { [papers = state.papers, previewReader, root] in
            for paper in papers {
                guard !Task.isCancelled else { return }
                try? await previewReader.prepare(paper: paper, root: root)
            }
        }
    }

    public func previewContent(for paperID: UUID) async -> PaperPreviewContent {
        guard let paper = state.papers.first(where: { $0.id == paperID }), !Task.isCancelled else { return .init() }
        var content =
            (try? await previewReader.read(paper: paper, root: root, store: pdfTranslations, settings: modelSettings))
            ?? .init()
        guard !Task.isCancelled else { return .init() }
        content.oneSentence = closeReadingTakeaway(for: paper)
        return content
    }

    private func closeReadingTakeaway(for paper: Paper) -> String? {
        guard let report = state.chats.last(where: { $0.paperID == paper.id && $0.closeReadingVersion != nil }) else {
            return nil
        }
        if let id = report.readingNoteID,
            let note = state.readingNotes.first(where: { $0.id == id && $0.paperID == paper.id && $0.deletedAt == nil }
            ),
            let sentence = PreviewTakeaway.fromNotebook(note.markdown)
        {
            return sentence
        }
        // Older close readings kept their thesis as an anchored margin note.
        let ids = Set(report.closeReadingNoteIDs ?? [])
        for note in state.readingNotes
        where ids.contains(note.id) && note.paperID == paper.id && note.deletedAt == nil
            && note.dimension == .thesis
        {
            if let sentence = PreviewTakeaway.firstSentence(in: note.markdown) { return sentence }
        }
        return nil
    }
}

private enum PreviewTakeaway {
    static func fromNotebook(_ markdown: String) -> String? {
        var heading = ""
        var legacy: String?
        for line in markdown.prefix(40_000).split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") {
                heading = text.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                continue
            }
            if heading == "一句话概括", let value = firstSentence(in: text) { return value }
            if legacy == nil, ["论点", "结论", "核心论点", "核心结论", "主要发现", "作者主张"].contains(heading) {
                legacy = firstSentence(in: text)
            }
        }
        return legacy
    }

    static func firstSentence(in markdown: String) -> String? {
        for raw in markdown.prefix(1_200).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("["), !line.hasPrefix(">"), !line.hasPrefix("!"),
                !line.hasPrefix("$$"), !line.hasPrefix("\u{60}\u{60}\u{60}"), !line.contains("paperreader://")
            else { continue }
            var value = (try? AttributedString(markdown: line)).map { String($0.characters) } ?? line
            value = value.replacingOccurrences(
                of: #"^(?:段落作用|通俗解释|核心论点|一句话概括)[\s:：]+"#, with: "", options: .regularExpression)
            guard !value.isEmpty else { continue }
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = value
            let first = value[tokenizer.tokenRange(at: value.startIndex)].trimmingCharacters(
                in: .whitespacesAndNewlines)
            if (6...280).contains(first.count) { return first }
        }
        return nil
    }
}
