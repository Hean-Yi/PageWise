import PaperReaderKit
import SwiftUI

struct AgentProcessView: View {
    let turn: AgentTurn
    let isRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsThinking = false
    @State private var stepsExpanded: Bool?
    @State private var inspectedCalls: Set<UUID> = []

    var body: some View {
        let thoughts = turn.processNotes.filter { $0.kind == .thinking }
        let progress = turn.processNotes.filter { $0.kind == .progress }
        VStack(alignment: .leading, spacing: 10) {
            if !thoughts.isEmpty {
                Button {
                    withAnimation(ReaderMotion.disclosure(reduceMotion)) { showsThinking.toggle() }
                } label: {
                    disclosureLabel("模型思考", icon: "text.bubble", expanded: showsThinking)
                }
                .readerIconButtonStyle(.plain)
                .accessibilityValue(showsThinking ? "已展开" : "已收起")
                if showsThinking {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(thoughts) { note in
                            Text(note.text).textSelection(.enabled)
                        }
                    }.modifier(ProcessInset())
                } else if let thought = isRunning ? thoughts.last : thoughts.first {
                    Text(thought.text).lineLimit(2).modifier(ProcessInset())
                }
            }

            if !turn.activities.isEmpty || !progress.isEmpty {
                let expanded = stepsExpanded ?? isRunning
                Button {
                    withAnimation(ReaderMotion.disclosure(reduceMotion)) { stepsExpanded = !expanded }
                } label: {
                    disclosureLabel(summary, icon: "list.bullet.indent", expanded: expanded)
                }
                .readerIconButtonStyle(.plain)
                .help(expanded ? "收起执行过程" : "查看执行过程")
                .accessibilityLabel("执行过程，\(summary)")
                .accessibilityValue(expanded ? "已展开" : "已收起")
                if expanded {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(turn.activities.enumerated()), id: \.element.id) { index, activity in
                            progressNotes(progress, before: index)
                            activityRow(activity)
                        }
                        progressNotes(progress, before: turn.activities.count)
                    }
                    .modifier(ProcessInset())
                } else if thoughts.isEmpty, let note = progress.last {
                    Text(note.text).lineLimit(2).modifier(ProcessInset())
                }
            }
        }
        .foregroundStyle(ReaderTheme.muted)
        .onChange(of: isRunning) { _, running in
            if !running { stepsExpanded = nil }
        }
    }

    private func disclosureLabel(_ title: String, icon: String, expanded: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).readerSymbolInk().frame(width: 15)
            Text(title).fontWeight(.medium).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            chevron(expanded: expanded)
        }
        .font(.caption).padding(.vertical, 3).contentShape(Rectangle())
    }

    private func chevron(expanded: Bool) -> some View {
        Image(systemName: "chevron.right").readerSymbolInk().font(.caption2)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .flipsForRightToLeftLayoutDirection(true)
            .accessibilityHidden(true)
    }

    private var summary: String {
        if isRunning, let active = turn.activities.last, active.status == .running {
            return "正在" + name(of: active)
        }
        if let last = turn.activities.last {
            if last.status == .failed { return name(of: last) + "失败" }
            if last.status == .cancelled { return "执行已停止" }
            if last.toolName == "ask_user" { return "已询问偏好" }
        }
        let searches = turn.activities.filter {
            ["search_library", "search_online", "recommend_related"].contains($0.toolName)
        }
        let papers = Set(
            searches.flatMap { turn.cards(for: $0) }.compactMap { $0.candidateID ?? $0.paperID?.uuidString })
        let recommendations = turn.presentedResults.filter { $0.purpose == .recommendation }.count
        if recommendations > 0, !papers.isEmpty { return "检索 \(papers.count) 篇 · 推荐 \(recommendations) 篇" }
        let noteSearches = turn.activities.filter { $0.toolName == "search_reading_notes" }
        if !noteSearches.isEmpty, papers.isEmpty {
            let count = Set(noteSearches.flatMap { turn.cards(for: $0) }.compactMap(\.readingNoteID)).count
            return count == 0 ? "未检索到匹配笔记" : "检索到 \(count) 条笔记"
        }
        if !papers.isEmpty { return "检索到 \(papers.count) 篇论文" }
        if searches.contains(where: { $0.toolName == "search_online" && $0.message != nil }) {
            return "部分来源未完成检索"
        }
        if !searches.isEmpty, searches.allSatisfy({ $0.resultCount == 0 }) { return "未检索到匹配论文" }
        return turn.activities.isEmpty ? "工作进展" : "执行过程 · \(turn.activities.count) 步"
    }

    private func progressNotes(_ notes: [AgentProcessNote], before index: Int) -> some View {
        ForEach(notes.filter { $0.beforeActivityCount == index }) { note in
            Text(note.text).contextMenu { AgentCopyButton(text: note.text) }
        }
    }

    private func activityRow(_ activity: AgentActivity) -> some View {
        let records = turn.cards(for: activity)
        let canInspect =
            !records.isEmpty
            && ["search_library", "search_online", "recommend_related", "search_reading_notes", "read_paper"].contains(
                activity.toolName)
        let opened = inspectedCalls.contains(activity.id)
        return VStack(alignment: .leading, spacing: 4) {
            if canInspect {
                Button {
                    withAnimation(ReaderMotion.disclosure(reduceMotion)) {
                        if opened { inspectedCalls.remove(activity.id) } else { inspectedCalls.insert(activity.id) }
                    }
                } label: {
                    stepLabel(activity, expanded: opened)
                }
                .readerIconButtonStyle(.plain).accessibilityValue(opened ? "已展开" : "已收起")
            } else {
                stepLabel(activity, expanded: nil)
            }
            if let subject = activity.subject, !subject.isEmpty {
                Text(subject).lineLimit(2).padding(.leading, 17)
            }
            if activity.status == .failed || activity.resultCount == 0 || activity.toolName == "search_online",
                let message = activity.message, !message.isEmpty, message != activity.subject
            {
                Text(message).padding(.leading, 17).contextMenu { AgentCopyButton(text: message) }
            }
            if canInspect && opened {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(records) { card in
                        let content =
                            ["read_paper", "search_reading_notes"].contains(activity.toolName) && !card.excerpt.isEmpty
                            ? card.excerpt : card.title
                        SearchMatchText(content, query: card.searchQuery)
                            .lineLimit(2).help(content).contextMenu { AgentCopyButton(text: content) }
                    }
                }.padding(.leading, 17)
            }
        }
    }

    private func stepLabel(_ activity: AgentActivity, expanded: Bool?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if activity.status == .running {
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            } else {
                Image(
                    systemName: activity.status == .failed
                        ? "exclamationmark.circle" : (activity.status == .cancelled ? "stop.circle" : "checkmark")
                )
                .readerSymbolInk().font(.caption2).frame(width: 12).accessibilityHidden(true)
            }
            Text(name(of: activity)).foregroundStyle(ReaderTheme.ink)
            if activity.status == .failed { Text("失败") }
            if activity.status == .cancelled { Text("已停止") }
            if let count = activity.resultCount,
                [
                    "search_library", "search_online", "recommend_related", "search_reading_notes", "read_paper",
                    "present_results",
                ].contains(
                    activity.toolName)
            {
                Text(activity.isTruncated ? "前 \(count) 项" : "\(count) 项").monospacedDigit()
            }
            if let expanded {
                Spacer(minLength: 0)
                chevron(expanded: expanded)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func name(of activity: AgentActivity) -> String {
        switch activity.toolName {
        case "list_library": "查看馆藏"
        case "create_shelf": "新建书架"
        case "rename_shelf": "重命名书架"
        case "move_papers": "整理论文归属"
        case "prepare_delete_shelf": "准备移除书架"
        case "prepare_delete_paper": "准备删除论文"
        case "prepare_local_import": "准备导入本地 PDF"
        case "search_library": "检索书库"
        case "search_reading_notes": "检索笔记"
        case "search_online": "在线检索论文"
        case "recommend_related": "检索相关论文"
        case "read_paper": "阅读原文"
        case "prepare_import": "准备导入"
        case "open_paper": "定位论文"
        case "present_results": "选定结果"
        case "ask_user": "询问偏好"
        case "close_read_paper": "精读论文"
        case "create_reading_note": "在原文记笔记"
        default: "调用工具"
        }
    }
}

private struct ProcessInset: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 11)
            .overlay(alignment: .leading) { Rectangle().fill(ReaderTheme.line).frame(width: 1) }
            .padding(.leading, 7)
    }
}
