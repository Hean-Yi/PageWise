import PaperReaderKit
import SwiftUI

/// Give the lazy stack one stable, independently measured row per message part, including each selected result.
private struct TranscriptRow: Identifiable {
    enum Part: Hashable {
        case question, process, answer
        case result(UUID)
        case clarification, status
    }

    struct ID: Hashable {
        let turn: UUID
        let part: Part
    }

    let id: ID
    let turn: AgentTurn
    let spacingBefore: CGFloat

    static func rows(for turns: [AgentTurn], activeQuestion: UUID?) -> [Self] {
        var rows: [Self] = []
        for turn in turns {
            func append(_ part: Part, spacing: CGFloat = 16) {
                rows.append(Self(id: ID(turn: turn.id, part: part), turn: turn, spacingBefore: spacing))
            }
            append(.question, spacing: rows.isEmpty ? 0 : 28)
            if !turn.activities.isEmpty || !turn.processNotes.isEmpty { append(.process) }
            if !turn.answer.isEmpty { append(.answer) }
            for (index, result) in turn.presentedResults.enumerated() {
                append(.result(result.id), spacing: index == 0 ? 16 : 8)
            }
            if turn.clarification != nil, turn.id != activeQuestion { append(.clarification) }
            if turn.error != nil || (turn.isCancelled && turn.activities.last?.status != .cancelled) { append(.status) }
        }
        return rows
    }
}

struct AgentTranscriptView: View {
    let agent: LibraryAgent
    let activeQuestionID: UUID?
    let didNavigate: () -> Void
    let followUp: (AgentCard) -> Void
    let retry: (AgentTurn) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        TranscriptRow.rows(
                            for: agent.turns,
                            activeQuestion: activeQuestionID)
                    ) { row in
                        content(row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, row.spacingBefore)
                    }
                    if agent.isRunning, let last = agent.turns.last, last.activities.isEmpty,
                        last.processNotes.isEmpty, last.answer.isEmpty
                    {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("正在准备回答…").font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                        }.padding(.top, 16)
                    }
                    Color.clear.frame(height: 1).id("agent-bottom")
                }.padding(20)
            }
            .modifier(
                JumpToLatest(
                    target: .init(turn: agent.turns.last?.id, awaitsReply: agent.pendingClarificationTurnID != nil)
                ) { proxy.scrollTo("agent-bottom", anchor: .bottom) })
        }
    }

    @ViewBuilder private func content(_ row: TranscriptRow) -> some View {
        let turn = row.turn
        switch row.id.part {
        case .question:
            VStack(alignment: .leading, spacing: 5) {
                if let title = turn.referencedCardTitle {
                    Label(title, systemImage: "text.quote").font(.caption).foregroundStyle(ReaderTheme.muted)
                        .lineLimit(2)
                }
                Text(turn.question).font(.callout).lineSpacing(4)
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(ReaderTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
            .agentCopyMenu(turn.question)
        case .process:
            AgentProcessView(turn: turn, isRunning: agent.isRunning && agent.turns.last?.id == turn.id)
        case .answer:
            AssistantMarkdownText(markdown: turn.answer)
        case .result(let id):
            if let result = turn.presentedResults.first(where: { $0.id == id }),
                let card = turn.cards.first(where: { $0.id == id })
            {
                AgentResultCard(result: result, group: card, agent: agent, didNavigate: didNavigate, followUp: followUp)
            }
        case .clarification:
            if let clarification = turn.clarification {
                Label(clarification.question, systemImage: "questionmark.bubble")
                    .font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
        case .status:
            if let error = turn.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(ReaderTheme.muted)
                    Button("重新提问") { retry(turn) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ReaderTheme.accent)
                }
            } else {
                Text("已停止").font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
            }
        }
    }

}

struct JumpToLatest: ViewModifier {
    struct Target: Equatable {
        let turn: UUID?
        let awaitsReply: Bool
    }

    let target: Target
    let jump: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasMoreBelow = false
    @State private var readerScrolled = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { readerScrolled = true }
            }
            .onChange(of: target) { previous, current in
                guard current.turn != nil else { return }
                if previous.turn != current.turn {
                    readerScrolled = false
                    jump()
                } else if current.awaitsReply && !readerScrolled {
                    jump()
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY > 48
            } action: { _, hasMore in
                hasMoreBelow = hasMore
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    readerScrolled = false
                    withAnimation(ReaderMotion.navigation(reduceMotion), jump)
                } label: {
                    Label {
                        Text("前往最新消息")
                    } icon: {
                        ReaderActionSymbol("arrow.down")
                    }
                }
                .labelStyle(.iconOnly).readerFloatingButton(.circle)
                .help("前往最新消息")
                .opacity(hasMoreBelow ? 1 : 0)
                .animation(ReaderMotion.feedback(reduceMotion), value: hasMoreBelow)
                .disabled(!hasMoreBelow).allowsHitTesting(hasMoreBelow).accessibilityHidden(!hasMoreBelow)
                .padding(.trailing, 15).padding(.bottom, 6)
            }
    }
}

extension View {
    func agentCopyMenu(_ text: String) -> some View {
        readerContextMenu(
            "文本操作",
            items: [
                .action("复制") {
                    #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    #else
                        UIPasteboard.general.string = text
                    #endif
                }
            ])
    }
}
