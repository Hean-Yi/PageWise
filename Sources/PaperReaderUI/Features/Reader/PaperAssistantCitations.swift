import PaperReaderKit
import SwiftUI

struct AssistantCitationAnchor: Hashable {
    let turn: UUID
    let source: String
}

struct PaperAssistantCitations: View {
    let turn: ChatTurn
    let model: ReaderModel
    let didNavigate: () -> Void
    let revealCard: (String) -> Void
    @State private var expandedExcerpts: Set<String> = []
    @State private var showsRelated = false
    @State private var previews: [String: String] = [:]

    @State private var citedIDs: [String] = []

    var body: some View {
        let sources = Dictionary(turn.evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cited = citedIDs.compactMap { sources[$0] }
        VStack(alignment: .leading, spacing: 9) {
            if !turn.evidence.isEmpty {
                DisclosureGroup("检索资料 · \(turn.evidence.count)", isExpanded: $showsRelated) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(turn.evidence) { source in processRow(source) }
                    }.padding(.top, 6)
                }.font(.caption).foregroundStyle(ReaderTheme.muted).tint(ReaderTheme.muted)
            }
            if !turn.answer.isEmpty {
                AssistantMarkdownText(
                    markdown: turn.answer, citationIDs: Set(sources.keys),
                    onCitations: { if citedIDs != $0 { citedIDs = $0 } },
                    onCitation: { id in
                        guard let source = sources[id] else { return }
                        if model.jump(to: source) {
                            didNavigate()
                        } else {
                            expandedExcerpts.insert(id)
                            revealCard(id)
                        }
                    }
                )
                .padding(.bottom, cited.isEmpty ? 0 : 3)
            }
            ForEach(cited) { source in card(source) }
            if let id = turn.readingNoteID {
                if let note = model.currentReadingNotes.first(where: { $0.id == id }) {
                    Button {
                        model.openReadingNote(note)
                        didNavigate()
                    } label: {
                        AssistantToolTile(
                            tool: turn.closeReadingVersion == nil ? "已记入原文" : "精读笔记", systemImage: "note.text",
                            title: turn.closeReadingVersion == nil
                                ? ReadingNoteSummary.excerpt(note.anchors.first?.text ?? "阅读笔记") : "全文论证骨架",
                            detail: turn.closeReadingVersion == nil ? ReadingNoteSummary.text(note.markdown) : nil,
                            metadata: note.anchors.count > 1 ? "\(note.anchors.count) 处" : nil,
                            accessory: "chevron.forward", detailLines: 1)
                    }.buttonStyle(AssistantToolButtonStyle()).accessibilityHint("定位并打开阅读笔记")
                } else {
                    Label("笔记已删除", systemImage: "note.text").font(.caption).foregroundStyle(ReaderTheme.muted)
                }
            }
            if let ids = turn.closeReadingNoteIDs {
                CloseReadingNoteList(ids: ids, model: model, didNavigate: didNavigate)
            }
        }
        .task(id: turn.id) {
            // A streaming answer changes many times; its evidence and original question are fixed.
            let excerpt = CitationExcerpt(question: turn.question, selection: turn.selection)
            previews = Dictionary(
                turn.evidence.map { ($0.id, excerpt.preview(of: $0.text)) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func currentExcerpt(_ source: Evidence) -> String {
        guard let id = source.readingNoteID, let paperID = source.paperID else { return source.text }
        guard let note = model.referencedReadingNote(id: id, paperID: paperID) else { return "" }
        let body = ReadingNoteMemoryIndex.searchableBody(note.markdown)
        return body.contains(source.text) ? source.text : ReadingNoteSummary.text(body)
    }

    private func processRow(_ source: Evidence) -> some View {
        let canNavigate = model.evidencePageKey(for: source) != nil
        let excerpt = currentExcerpt(source)
        let key = "process-" + source.id
        let expanded = expandedExcerpts.contains(key)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if canNavigate, model.jump(to: source) {
                    didNavigate()
                } else if expanded {
                    expandedExcerpts.remove(key)
                } else {
                    expandedExcerpts.insert(key)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(source.id).monospacedDigit()
                    Text(source.title).foregroundStyle(ReaderTheme.ink).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: canNavigate ? "arrow.up.forward" : (expanded ? "chevron.up" : "chevron.down"))
                        .imageScale(.small).accessibilityHidden(true)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!canNavigate && excerpt.isEmpty)
            if expanded { Text(excerpt).textSelection(.enabled) }
        }
    }

    private func card(_ source: Evidence) -> some View {
        let key = model.evidencePageKey(for: source)
        let isNote = source.readingNoteID != nil || source.notePath != nil
        let excerpt = currentExcerpt(source)
        let expanded = expandedExcerpts.contains(source.id)
        let canExpand = key == nil && !excerpt.isEmpty
        let marker =
            key?.hasPrefix("original-") == true
            ? source.sourcePage.map { "第 \($0 + 1) 页" } : nil
        let metadata = [source.id, marker].compactMap { $0 }.joined(separator: " · ")
        let subject = isNote ? "笔记" : (key == nil ? "摘录" : "原文")
        let tool = source.readingNoteID != nil && excerpt.isEmpty ? "笔记已不可用" : "引用" + subject
        let tile = AssistantToolTile(
            tool: tool, systemImage: isNote ? "note.text" : "quote.opening", title: source.title,
            detail: expanded || excerpt.isEmpty
                ? nil : (source.readingNoteID == nil ? previews[source.id] : ReadingNoteSummary.excerpt(excerpt)),
            metadata: metadata,
            accessory: key != nil ? "chevron.forward" : (canExpand ? (expanded ? "chevron.up" : "chevron.down") : nil))
        return Group {
            if key != nil {
                Button {
                    if model.jump(to: source) { didNavigate() }
                } label: {
                    tile
                }
                .buttonStyle(AssistantToolButtonStyle())
                .accessibilityHint("前往引用位置")
            } else if canExpand {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        if expanded { expandedExcerpts.remove(source.id) } else { expandedExcerpts.insert(source.id) }
                    } label: {
                        tile
                    }
                    .buttonStyle(AssistantToolButtonStyle(embedded: true))
                    .accessibilityHint(expanded ? "收起摘录" : "展开摘录")
                    if expanded {
                        Divider().accessibilityHidden(true)
                        Text(excerpt).font(.callout).lineSpacing(3).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .assistantToolSurface()
            } else {
                tile.assistantToolSurface()
            }
        }
        .help(source.title)
        .id(AssistantCitationAnchor(turn: turn.id, source: source.id))
    }
}
