import PaperReaderKit
import SwiftUI

struct AgentResultCard: View {
    let card: AgentCard
    let open: () -> Void
    let importPaper: () -> Void
    let stopImport: () -> Void

    var body: some View {
        Group {
            if card.kind == .onlineCandidate {
                onlineCard
            } else {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 12) {
                        heading(icon: card.kind == .evidence ? "text.alignleft" : "doc.text")
                        if !card.excerpt.isEmpty {
                            Text(card.excerpt).font(.system(size: 12)).lineSpacing(4)
                                .foregroundStyle(ReaderTheme.muted).lineLimit(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 6) {
                            Text(card.sourcePage.map { "前往第 \($0) 页" } ?? "打开论文")
                            Image(systemName: "arrow.up.right")
                        }.font(.system(size: 11, weight: .medium)).foregroundStyle(ReaderTheme.accent)
                    }.padding(15).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!card.canOpen)
                    .accessibilityLabel("\(card.title)，\(card.sourcePage.map { "原文第 \($0) 页" } ?? "打开论文")")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ReaderTheme.line))
    }

    private var onlineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(icon: "globe")
            if let error = card.importError {
                Text(error).font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let source = card.sourceURL {
                    Link(destination: source) {
                        Label("arXiv", systemImage: "arrow.up.right")
                    }.font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                        .help("查看论文来源")
                }
                Spacer(minLength: 0)
                importControl
            }
        }.padding(15)
    }

    private func heading(icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14))
                .foregroundStyle(ReaderTheme.muted).frame(width: 30, height: 34)
                .background(ReaderTheme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 5) {
                Text(card.title).font(.system(size: 13, weight: .medium)).foregroundStyle(ReaderTheme.ink)
                    .lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                if !card.subtitle.isEmpty {
                    Text(card.subtitle).font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var importControl: some View {
        switch card.importState {
        case .downloading, .importing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(card.importState == .downloading ? "下载中" : "整理中").font(.system(size: 11))
                Button(action: stopImport) { Image(systemName: "stop.circle") }
                    .buttonStyle(.plain).help("停止导入").accessibilityLabel("停止导入 \(card.title)")
            }.foregroundStyle(ReaderTheme.muted)
        case .imported:
            Button(action: open) { Label("已入库 · 打开", systemImage: "checkmark") }
                .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
        default:
            Button(action: importPaper) {
                Label(card.importState == .failed ? "重试导入" : "导入论文", systemImage: "arrow.down")
            }.buttonStyle(.bordered).controlSize(.small).disabled(!card.canImport)
                .help("确认下载并添加到本地书库")
        }
    }
}

struct AgentActivityLog: View {
    let activities: [AgentActivity]
    @State private var expanded = false

    var body: some View {
        if let latest = activities.last {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(activities) { item in row(item) }
                }.padding(.top, 8).padding(.leading, 2)
            } label: {
                row(latest)
            }.font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                .tint(ReaderTheme.muted)
        }
    }

    private func row(_ item: AgentActivity) -> some View {
        HStack(spacing: 7) {
            if item.status == .running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: item.status == .succeeded ? "checkmark" : "exclamationmark.circle")
                    .font(.system(size: 10))
            }
            Text(title(for: item.toolName))
            if let count = item.resultCount { Text("· \(count) 个结果") }
            Spacer(minLength: 0)
        }.help(item.message ?? title(for: item.toolName))
    }

    private func title(for tool: String) -> String {
        switch tool {
        case "search_library": "检索书库"
        case "read_paper": "阅读原文"
        case "search_online": "查找 arXiv"
        case "prepare_import": "准备导入"
        case "open_paper": "定位论文"
        default: "工具调用"
        }
    }
}
