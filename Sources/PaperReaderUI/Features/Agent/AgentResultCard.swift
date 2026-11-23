import PaperReaderKit
import SwiftUI

/// A selected result always keeps the identity and actions of its registered source.
struct AgentResultCard: View {
    let result: AgentPresentedResult
    let card: AgentCard
    let agent: LibraryAgent
    let didNavigate: () -> Void
    let followUp: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var showsExcerpt = false

    private var purpose: (title: String, icon: String) {
        switch result.purpose {
        case .recommendation: ("推荐论文", "bookmark")
        case .citation: ("引用原文", "quote.opening")
        case .match: ("检索结果", card.kind == .onlineCandidate ? "globe" : "books.vertical")
        case .navigation: ("定位论文", "location")
        case .importAction: ("导入论文", "arrow.down.doc")
        case .readingNote: ("阅读笔记", "note.text")
        }
    }

    private var metadata: String? {
        if card.kind == .onlineCandidate {
            return ["arXiv", card.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return card.sourcePage.map { "第 \($0) 页" }
    }

    var body: some View {
        if card.readingNoteID != nil && !agent.canOpen(card) {
            Label("笔记已删除或原文不可用", systemImage: "note.text")
                .font(.caption).foregroundStyle(ReaderTheme.muted)
        } else {
            resultTile
        }
    }

    private var resultTile: some View {
        VStack(alignment: .leading, spacing: 0) {
            primaryAction
            if let error = card.importError {
                Text(error).font(.caption).foregroundStyle(ReaderTheme.muted)
                    .padding(.horizontal, 12).padding(.bottom, 7).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(action: followUp) {
                    Label("追问", systemImage: "bubble.left")
                }
                .buttonStyle(.borderless).foregroundStyle(ReaderTheme.muted)
                .help("基于这项结果追问").accessibilityLabel("基于《\(card.title)》追问")
                .disabled(agent.isRunning)
                Spacer(minLength: 4)
                if card.kind == .onlineCandidate { importAction }
            }
            .font(.caption).padding(.horizontal, 12).padding(.bottom, 9)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous)).assistantToolSurface()
    }

    @ViewBuilder private var primaryAction: some View {
        if card.kind == .onlineCandidate, let url = card.sourceURL {
            Button {
                openURL(url)
            } label: {
                label(accessory: "arrow.up.right")
            }
            .buttonStyle(AssistantToolButtonStyle(embedded: true)).help("在 arXiv 查看《\(card.title)》")
            .accessibilityHint("在浏览器中查看论文")
        } else if agent.canOpen(card) {
            Button(action: open) { label(accessory: "chevron.forward") }
                .buttonStyle(AssistantToolButtonStyle(embedded: true)).help(card.title)
                .accessibilityHint("在阅读器中打开")
        } else if card.readingNoteID != nil {
            Label("笔记已删除或不可用", systemImage: "note.text").font(.caption)
                .foregroundStyle(ReaderTheme.muted).padding(12)
        } else if !card.excerpt.isEmpty {
            Button {
                showsExcerpt.toggle()
            } label: {
                label(accessory: showsExcerpt ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(AssistantToolButtonStyle(embedded: true))
            .accessibilityHint(showsExcerpt ? "收起摘录" : "查看完整摘录")
            if showsExcerpt {
                Text(card.excerpt).font(.callout).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
        } else {
            label(accessory: nil)
        }
    }

    private func label(accessory: String?) -> some View {
        let detail: String?
        if let id = card.readingNoteID {
            let note = agent.reader.state.readingNotes.first {
                $0.id == id && $0.paperID == card.paperID && $0.deletedAt == nil
            }
            detail = note.map { ReadingNoteSummary.text($0.markdown) }
        } else {
            detail = card.kind == .onlineCandidate ? card.authors : (showsExcerpt ? nil : card.excerpt)
        }
        return VStack(alignment: .leading, spacing: 0) {
            AssistantToolTile(
                tool: purpose.title, systemImage: purpose.icon, title: card.title, detail: detail,
                metadata: metadata, accessory: accessory, detailLines: card.readingNoteID == nil ? 2 : 1)
            if let reason = result.reason, !reason.isEmpty {
                Text(reason).font(.caption).lineSpacing(2).foregroundStyle(ReaderTheme.ink)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 9)
            }
        }
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }

    private func open() {
        if agent.open(cardID: card.id) { didNavigate() }
    }

    @ViewBuilder private var importAction: some View {
        switch card.importState {
        case .downloading, .importing:
            ProgressView().controlSize(.mini)
            Text(card.importState == .downloading ? "下载中" : "整理中").foregroundStyle(ReaderTheme.muted)
            Button {
                agent.cancelImport(cardID: card.id)
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless).help("停止导入").accessibilityLabel("停止导入 \(card.title)")
        case .imported:
            Button(action: open) { Label("在书库打开", systemImage: "books.vertical") }
                .buttonStyle(.borderless).disabled(!agent.canOpen(card))
        default:
            Button {
                agent.confirmImport(cardID: card.id)
            } label: {
                Label(
                    card.importState == .failed || card.importState == .cancelled ? "重新导入" : "导入论文",
                    systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(!card.canImport)
            .help("下载并添加到书库").accessibilityHint(card.title)
        }
    }
}
