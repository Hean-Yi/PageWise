import SwiftUI

enum AssistantTab: String, CaseIterable {
    case paper = "论文助读"
    case notes = "笔记"
    case library = "书库助理"

    var icon: ReaderIcon.Glyph {
        switch self {
        case .paper: .discussion
        case .notes: .notebook
        case .library: .library
        }
    }
}

struct WorkspaceAssistantSidebar: View {
    let model: ReaderModel
    let agent: LibraryAgent
    let isReading: Bool
    let tab: AssistantTab
    let select: (AssistantTab) -> Void
    @Binding var question: String
    @Binding var agentDraft: String
    var showsCloseButton = false
    var onClose: (() -> Void)?
    let openSettings: () -> Void
    let didNavigate: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if isReading {
                    tabBar
                } else {
                    Label {
                        Text(AssistantTab.library.rawValue)
                    } icon: {
                        ReaderIcon(.library, size: 18)
                    }
                    .font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                if showsCloseButton, let onClose {
                    Button(action: onClose) {
                        ReaderIcon(.close, size: 14).readerIconTarget(macOS: 28)
                    }
                    .readerIconButtonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                    .help("收起助读侧栏（⌥⌘I）").accessibilityLabel("收起助读侧栏")
                }
            }.padding(.horizontal, 14).frame(height: 56)
            Divider()
            let index = AssistantTab.allCases.firstIndex(of: tab) ?? 0
            tabContent.modifier(
                WorkspaceArrival(
                    destination: CGPoint(x: CGFloat(index) * 12, y: 0), background: ReaderTheme.canvas,
                    usesCompactNavigation: false)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderTheme.canvas)
        .overlay(alignment: .leading) { Rectangle().fill(ReaderTheme.line).frame(width: 1) }
        .onKeyPress(.escape) {
            guard showsCloseButton, let onClose else { return .ignored }
            onClose()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("助读侧栏")
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AssistantTab.allCases, id: \.self) { item in
                let selected = tab == item
                Button {
                    if !selected { select(item) }
                } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            tabIcon(item)
                            Text(item.rawValue).font(.callout.weight(.medium))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        tabIcon(item)
                    }
                    .padding(.horizontal, 4)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    #if os(macOS)
                        .frame(minHeight: 34)
                    #else
                        .frame(minHeight: 44)
                    #endif
                    .foregroundStyle(selected ? ReaderTheme.accent : ReaderTheme.muted)
                    .sidebarSelectionTarget(selected)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .readerIconButtonStyle(.plain)
                .help(item.rawValue).accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .sidebarSelectionIndicator(for: tab, in: Capsule(), reduceMotion: reduceMotion)
    }

    private func tabIcon(_ item: AssistantTab) -> some View {
        ZStack {
            if model.busyAI && item == tab && item != .library {
                ProgressView().controlSize(.small)
            } else {
                ReaderIcon(item.icon, size: 17)
            }
        }
        .frame(width: 17, height: 17)
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .library:
            LibraryAgentView(
                agent: agent, model: model, draft: $agentDraft, openSettings: openSettings, didNavigate: didNavigate
            )
        case .notes:
            ReaderNotesView(
                model: model,
                summarize: {
                    if model.isModelReadyForRequests {
                        Task { await model.summarize() }
                    } else {
                        openSettings()
                    }
                }, didNavigate: didNavigate)
        case .paper:
            PaperAssistantView(
                model: model, question: $question, openSettings: openSettings, didNavigate: didNavigate,
                relatedPapers: {
                    guard model.isModelReadyForRequests else {
                        openSettings()
                        return
                    }
                    select(.library)
                    agent.findRelatedToCurrentPaper()
                }, canFindRelated: !agent.isRunning && model.paper != nil)
        }
    }
}
