import PaperReaderKit
import SwiftUI

/// A selected result always keeps the identity and actions of its registered source.
struct AgentResultCard: View {
    let result: AgentPresentedResult
    let group: AgentCard
    let agent: LibraryAgent
    let didNavigate: () -> Void
    let followUp: (AgentCard) -> Void
    @Environment(\.openURL) private var openURL
    @State private var showsExcerpt = false
    @State private var selectedVersion: UUID?

    private var versions: [AgentCard] {
        [group] + group.alternateVersionIDs.compactMap { agent.card($0) }
    }

    private var selectedCard: AgentCard {
        if let selectedVersion, group.alternateVersionIDs.contains(selectedVersion),
            let card = agent.card(selectedVersion)
        {
            return card
        }
        return agent.currentImportCard(group)
    }

    private func versionLabel(_ item: AgentCard) -> String {
        let suffix = item.sourceURL.flatMap { ArxivClient.versionedIdentifier($0.absoluteString) }?
            .split(separator: "v").last
        let version = suffix.map { "v" + String($0) }
        return [item.sourceName, version, item.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func purpose(for card: AgentCard) -> (title: String, icon: String) {
        switch card.readingNoteID == nil ? result.purpose : .readingNote {
        case .recommendation: ("推荐论文", "bookmark")
        case .citation: ("引用原文", "quote.opening")
        case .match: ("检索结果", card.kind == .onlineCandidate ? "globe" : "books.vertical")
        case .navigation: ("定位论文", "location")
        case .importAction: ("导入论文", "arrow.down.doc")
        case .readingNote: ("阅读笔记", "note.text")
        }
    }

    private func metadata(for card: AgentCard) -> String? {
        if card.kind == .onlineCandidate {
            let link =
                !card.canAttemptDownload || card.importState == .failed
                ? PaperCandidate.landingPageLabel(for: card.sourceURL) : nil
            return [card.sourceName, card.year, link].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return card.sourcePage.map { "第 \($0) 页" }
    }

    var body: some View {
        let card = selectedCard
        if card.readingNoteID != nil && !agent.canOpen(card) {
            Label("笔记已删除或原文不可用", systemImage: "note.text")
                .font(.caption).foregroundStyle(ReaderTheme.muted)
        } else {
            resultTile(for: card)
        }
    }

    private func resultTile(for card: AgentCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !group.alternateVersionIDs.isEmpty {
                Menu {
                    ForEach(versions) { version in
                        Button {
                            selectedVersion = version.id
                        } label: {
                            if version.id == card.id {
                                Label(versionLabel(version), systemImage: "checkmark")
                            } else {
                                Text(versionLabel(version))
                            }
                        }
                    }
                } label: {
                    Label(versionLabel(card), systemImage: "square.stack")
                }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
                .padding(.leading, 12).padding(.top, 8).accessibilityLabel("选择论文版本")
            }
            primaryAction(for: card)
            if let error = card.importError {
                Text(error).font(.caption).foregroundStyle(ReaderTheme.muted)
                    .padding(.horizontal, 12).padding(.bottom, 7).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if card.kind == .onlineCandidate {
                    importAction(for: card)
                    Spacer(minLength: 4)
                }
                Button {
                    followUp(card)
                } label: {
                    Label("追问", systemImage: "bubble.left")
                }
                .buttonStyle(.borderless).foregroundStyle(ReaderTheme.muted)
                .help("基于这项结果追问").accessibilityLabel("基于《\(card.title)》追问")
                .disabled(agent.isRunning)
            }
            .labelStyle(.titleAndIcon).font(.caption).padding(.horizontal, 12).padding(.bottom, 9)
            if card.canAttemptDownload && card.importState == .failed {
                fileImportAction(for: card).font(.caption).padding(.horizontal, 12).padding(.bottom, 9)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous)).assistantToolSurface()
    }

    @ViewBuilder private func primaryAction(for card: AgentCard) -> some View {
        if card.kind == .onlineCandidate, let url = card.sourceURL {
            Button {
                openURL(url)
            } label: {
                label(for: card, accessory: "arrow.up.right")
            }
            .buttonStyle(AssistantToolButtonStyle(embedded: true)).help(PaperCandidate.landingPageLabel(for: url))
            .accessibilityHint("在浏览器中查看论文")
        } else if agent.canOpen(card) {
            Button {
                open(card)
            } label: {
                label(for: card, accessory: "chevron.forward")
            }
            .buttonStyle(AssistantToolButtonStyle(embedded: true)).help(card.title)
            .accessibilityHint("在阅读器中打开")
        } else if !card.excerpt.isEmpty {
            Button {
                showsExcerpt.toggle()
            } label: {
                label(for: card, accessory: showsExcerpt ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(AssistantToolButtonStyle(embedded: true))
            .accessibilityHint(showsExcerpt ? "收起摘录" : "查看完整摘录")
            if showsExcerpt {
                SearchMatchText(card.excerpt, query: card.searchQuery).font(.callout).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
        } else {
            label(for: card, accessory: nil)
        }
    }

    private func label(for card: AgentCard, accessory: String?) -> some View {
        let purpose = purpose(for: card)
        let detail: String?
        if let id = card.readingNoteID, let paperID = card.paperID {
            detail = agent.reader.referencedReadingNote(id: id, paperID: paperID).map { note in
                ReadingNoteSummary.text(card.noteModifiedAt == note.modifiedAt ? card.excerpt : note.markdown)
            }
        } else {
            detail = card.kind == .onlineCandidate ? card.authors : (showsExcerpt ? nil : card.excerpt)
        }
        return VStack(alignment: .leading, spacing: 0) {
            AssistantToolTile(
                tool: purpose.title, systemImage: purpose.icon, title: card.title, detail: detail,
                metadata: metadata(for: card), accessory: accessory,
                detailLines: result.purpose == .readingNote ? 1 : 2,
                searchQuery: card.searchQuery)
            if let reason = result.reason, !reason.isEmpty {
                Text(reason).font(.caption).lineSpacing(2).foregroundStyle(ReaderTheme.ink)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 9)
            }
        }
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }

    private func open(_ card: AgentCard) {
        if agent.open(cardID: card.id) { didNavigate() }
    }

    @ViewBuilder private func importAction(for card: AgentCard) -> some View {
        switch card.importState {
        case .queued, .downloading, .importing:
            if card.importState == .queued {
                Label("等待导入", systemImage: "clock").foregroundStyle(ReaderTheme.muted)
            } else {
                ProgressView().controlSize(.mini)
                Text(card.importState == .importing ? "正在入库" : (card.hasDownload ? "下载中" : "获取开放全文")).foregroundStyle(
                    ReaderTheme.muted)
            }
            let cancelTitle = card.importState == .queued ? "取消排队" : "停止导入"
            Button {
                agent.cancelImport(cardID: card.id)
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless).help(cancelTitle).accessibilityLabel("\(cancelTitle) \(card.title)")
        case .imported:
            Button {
                open(card)
            } label: {
                Label("在书库打开", systemImage: "books.vertical")
            }
            .buttonStyle(.bordered).disabled(!agent.canOpen(card))
            .accessibilityHint(card.title)
        case .unprepared, .ready, .failed, .cancelled:
            let cardID = card.id
            if card.canAttemptDownload {
                let title = card.importState == .failed || card.importState == .cancelled ? "重新下载" : "下载并导入"
                Button {
                    agent.confirmImport(cardID: cardID)
                } label: {
                    Label(title, systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent).tint(ReaderTheme.accent).disabled(!card.canImport)
                .help("下载并添加到书库").accessibilityHint(card.title)
            } else {
                fileImportAction(for: card)
            }
        }
    }

    private func fileImportAction(for card: AgentCard) -> some View {
        PublisherPDFImportButton(
            importFile: { agent.importPublisherPDF($0, cardID: card.id) },
            onFailure: { agent.publisherFileSelectionFailed($0, cardID: card.id) }
        )
        .id(card.id).accessibilityHint(card.title)
    }
}
