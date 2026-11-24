import SwiftUI

enum AssistantTab: String, CaseIterable {
    case paper = "论文助读"
    case notes = "笔记"
    case library = "书库助理"

    var icon: String {
        switch self {
        case .paper: "text.bubble"
        case .notes: "note.text"
        case .library: "books.vertical"
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
    let openSettings: () -> Void
    let saveNote: () -> Void
    let didNavigate: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if isReading {
                    tabBar
                } else {
                    Label(AssistantTab.library.rawValue, systemImage: AssistantTab.library.icon)
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                if model.busyAI && isReading {
                    ProgressView().controlSize(.small).opacity(tab == .library ? 0 : 1)
                        .accessibilityHidden(tab == .library)
                }
            }.padding(.horizontal, 14).frame(height: 56)
            Divider()
            ZStack {
                tabContent.id(tab).transition(.opacity)
            }
            .animation(ReaderMotion.disclosure(reduceMotion), value: tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderTheme.canvas)
        .overlay(alignment: .leading) { Rectangle().fill(ReaderTheme.line).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("助读侧栏")
    }

    private var tabBar: some View {
        let tabs = AssistantTab.allCases
        return HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { item in
                let selected = tab == item
                Button {
                    if !selected { select(item) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                        if selected {
                            Text(item.rawValue).font(.callout.weight(.medium)).lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 4)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    #if os(macOS)
                        .frame(minHeight: 34)
                    #else
                        .frame(minHeight: 44)
                    #endif
                    .foregroundStyle(selected ? ReaderTheme.accent : ReaderTheme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.rawValue).accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background {
            GeometryReader { geometry in
                let width = geometry.size.width / CGFloat(tabs.count)
                if let index = tabs.firstIndex(of: tab) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: CGFloat(index) * width)
                        tabIndicator.padding(.horizontal, 2).frame(width: width)
                    }
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .animation(ReaderMotion.navigation(reduceMotion), value: tab)
    }

    @ViewBuilder private var tabIndicator: some View {
        let paperCapsule = Capsule().fill(ReaderTheme.elevated)
        #if os(macOS)
            if #available(macOS 26, *), !reduceTransparency {
                Color.clear.glassEffect(.regular, in: .capsule)
            } else {
                paperCapsule
            }
        #else
            paperCapsule
        #endif
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
                    if (try? model.modelSettings.normalized()) != nil {
                        Task { await model.summarize() }
                    } else {
                        openSettings()
                    }
                }, saveNote: saveNote, didNavigate: didNavigate)
        case .paper:
            PaperAssistantView(
                model: model, question: $question, openSettings: openSettings, didNavigate: didNavigate,
                relatedPapers: {
                    guard (try? model.modelSettings.normalized()) != nil else {
                        openSettings()
                        return
                    }
                    select(.library)
                    agent.findRelatedToCurrentPaper()
                }, canFindRelated: !agent.isRunning && model.paper != nil)
        }
    }
}
