import PaperReaderKit
import SwiftUI

struct AssistantCitationAnchor: Hashable {
    let turn: UUID
    let source: String
}

/// Creates links only for reference markers matched against this answer's saved evidence.
/// The rest of the answer is plain text, including any URL returned by the model.
struct CitedAssistantAnswer {
    let text: AttributedString
    let cited: [Evidence]
    let related: [Evidence]
    let links: [URL: Evidence]

    init(_ turn: ChatTurn) {
        let sources = Dictionary(turn.evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = AttributedString()
        var cited: [Evidence] = []
        var links: [URL: Evidence] = [:]
        var cursor = turn.answer.startIndex
        for match in turn.answer.matches(of: /\[(S[0-9]+)\]/) {
            let id = String(match.1)
            guard let source = sources[id],
                let url = URL(string: "paperreader-citation://source/\(turn.id.uuidString)/\(id)")
            else { continue }
            result.append(AttributedString(turn.answer[cursor..<match.range.lowerBound]))
            var reference = AttributedString(String(match.0))
            reference.link = url
            result.append(reference)
            cursor = match.range.upperBound
            if links.updateValue(source, forKey: url) == nil { cited.append(source) }
        }
        result.append(AttributedString(turn.answer[cursor...]))
        let ids = Set(cited.map(\.id))
        self.text = result
        self.links = links
        self.cited = cited
        related = turn.evidence.filter { !ids.contains($0.id) }
    }
}

struct PaperAssistantCitations: View {
    let turn: ChatTurn
    let model: ReaderModel
    let didNavigate: () -> Void
    let revealCard: (String) -> Void
    @State private var expandedExcerpts: Set<String> = []
    @State private var showsRelated = false
    @State private var previews: [String: String] = [:]

    var body: some View {
        let answer = CitedAssistantAnswer(turn)
        VStack(alignment: .leading, spacing: 9) {
            if !turn.answer.isEmpty {
                Text(answer.text).font(.callout).textSelection(.enabled).lineSpacing(5)
                    .tint(ReaderTheme.accent)
                    .environment(
                        \.openURL,
                        OpenURLAction { url in
                            guard let source = answer.links[url] else { return .discarded }
                            if model.jump(to: source) {
                                didNavigate()
                            } else {
                                expandedExcerpts.insert(source.id)
                                revealCard(source.id)
                            }
                            return .handled
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, answer.cited.isEmpty ? 0 : 3)
            }
            ForEach(answer.cited) { source in card(source, cited: true) }
            if !answer.related.isEmpty {
                DisclosureGroup("检索资料 · \(answer.related.count)", isExpanded: $showsRelated) {
                    VStack(spacing: 8) {
                        ForEach(answer.related) { source in card(source, cited: false) }
                    }.padding(.top, 6)
                }.font(.caption).foregroundStyle(ReaderTheme.muted).tint(ReaderTheme.muted)
            }
        }
        .task(id: turn.id) {
            // A streaming answer changes many times; its evidence and original question are fixed.
            let excerpt = CitationExcerpt(question: turn.question, selection: turn.selection)
            previews = Dictionary(
                turn.evidence.map { ($0.id, excerpt.preview(of: $0.text)) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func card(_ source: Evidence, cited: Bool) -> some View {
        let key = model.evidencePageKey(for: source)
        let isNote = source.notePath != nil && source.paperID == nil
        let excerpt = source.text
        let expanded = expandedExcerpts.contains(source.id)
        let canExpand = key == nil && !excerpt.isEmpty
        let marker =
            key?.hasPrefix("original-") == true
            ? source.sourcePage.map { "第 \($0 + 1) 页" } : nil
        let metadata = [source.id, marker].compactMap { $0 }.joined(separator: " · ")
        let subject = isNote ? "笔记" : (key == nil ? "摘录" : "原文")
        let tool = (cited ? "引用" : "检索") + subject
        let tile = AssistantToolTile(
            tool: tool, systemImage: isNote ? "note.text" : "quote.opening", title: source.title,
            detail: expanded || excerpt.isEmpty ? nil : previews[source.id],
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
