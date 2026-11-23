import PaperReaderKit
import SwiftUI

/// One surface per executed call. Its actions address only the records returned by that call.
struct AgentActivityCard: View {
    let activity: AgentActivity
    let cards: [AgentCard]
    let agent: LibraryAgent
    let didNavigate: () -> Void
    @State private var expanded = false

    private var tool: (name: String, icon: String) {
        switch activity.toolName {
        case "search_library": ("检索书库", "books.vertical")
        case "read_paper": ("阅读原文", "text.viewfinder")
        case "search_online": ("检索 arXiv", "globe")
        case "prepare_import": ("准备导入", "arrow.down.doc")
        case "open_paper": ("定位论文", "location")
        default: ("工具调用", "wrench")
        }
    }

    var body: some View {
        if activity.status == .succeeded, let first = cards.first {
            if cards.count == 1 {
                result(first, grouped: false)
            } else {
                VStack(spacing: 0) {
                    Button {
                        expanded.toggle()
                    } label: {
                        AssistantToolTile(
                            tool: tool.name, systemImage: tool.icon, title: activity.subject ?? first.title,
                            metadata: "\(cards.count) 项结果", accessory: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(AssistantToolButtonStyle(embedded: true))
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                    if expanded {
                        ForEach(cards) { card in
                            Divider().padding(.horizontal, 12)
                            result(card, grouped: true)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous)).assistantToolSurface()
            }
        } else {
            status
        }
    }

    private func result(_ card: AgentCard, grouped: Bool) -> some View {
        AgentResultCard(
            tool: tool.name, icon: tool.icon, card: card, grouped: grouped,
            excerptFirst: grouped && activity.toolName == "read_paper", agent: agent, didNavigate: didNavigate)
    }

    private var status: some View {
        let state: String =
            switch activity.status {
            case .running: "进行中"
            case .succeeded: activity.isTruncated ? "达到结果上限" : "无结果"
            case .failed: "调用失败"
            case .cancelled: "已停止"
            }
        let title = activity.subject ?? activity.message ?? state
        let detail = activity.message.flatMap { $0 == title || $0 == state ? nil : $0 }
        return VStack(alignment: .leading, spacing: 0) {
            AssistantToolTile(
                tool: tool.name, systemImage: tool.icon, title: title,
                detail: detail, metadata: title == state ? nil : state)
            if activity.status == .running {
                ProgressView().progressViewStyle(.linear).controlSize(.mini)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .accessibilityHidden(true)
            }
        }.assistantToolSurface()
    }
}

private struct AgentResultCard: View {
    let tool: String
    let icon: String
    let card: AgentCard
    let grouped: Bool
    let excerptFirst: Bool
    let agent: LibraryAgent
    let didNavigate: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var showsExcerpt = false

    private var metadata: String? {
        if card.kind == .onlineCandidate { return card.year }
        if let page = card.sourcePage { return "第 \(page) 页" }
        return nil
    }

    private var detail: String {
        card.kind == .onlineCandidate ? card.authors ?? "" : card.excerpt
    }

    var body: some View {
        if grouped {
            content
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .assistantToolSurface()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if grouped && card.kind == .onlineCandidate {
                HStack(spacing: 0) {
                    primaryAction
                    importAction.labelStyle(.iconOnly).padding(.trailing, 8)
                }
            } else {
                primaryAction
            }
            if let error = card.importError {
                Text(error).font(.caption).foregroundStyle(ReaderTheme.muted)
                    .padding(.horizontal, 12).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
            }
            if !grouped && card.kind == .onlineCandidate {
                HStack {
                    Spacer()
                    importAction
                }.font(.caption).padding(.horizontal, 12).padding(.bottom, 9)
            }
        }
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

    @ViewBuilder private func label(accessory: String?) -> some View {
        if grouped {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(excerptFirst ? card.excerpt : card.title)
                        .font(.callout.weight(excerptFirst ? .regular : .medium)).lineLimit(2)
                    if !excerptFirst {
                        let summary = [metadata, showsExcerpt ? nil : detail].compactMap { $0 }.filter { !$0.isEmpty }
                            .joined(
                                separator: " · ")
                        if !summary.isEmpty {
                            Text(summary).font(.caption).foregroundStyle(ReaderTheme.muted).lineLimit(2)
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let accessory {
                    Image(systemName: accessory).font(.caption2).foregroundStyle(ReaderTheme.muted)
                        .accessibilityHidden(true)
                }
            }
            .multilineTextAlignment(.leading).padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        } else {
            AssistantToolTile(
                tool: tool, systemImage: icon, title: card.title, detail: showsExcerpt ? nil : detail,
                metadata: metadata, accessory: accessory)
        }
    }

    private func open() {
        if agent.open(cardID: card.id) { didNavigate() }
    }

    @ViewBuilder private var importAction: some View {
        switch card.importState {
        case .downloading, .importing:
            ProgressView().controlSize(.mini)
            if !grouped {
                Text(card.importState == .downloading ? "下载中" : "整理中").foregroundStyle(ReaderTheme.muted)
            }
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
