import PaperReaderKit
import SwiftUI
import UniformTypeIdentifiers

public struct LibraryView: View {
    @Bindable var model: ReaderModel
    @State private var agent: LibraryAgent
    @State private var showAgent = false
    @State private var agentDraft = ""
    @State private var pendingAgentSettings = false
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var dragTarget = false
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var toast: String?
    @State private var collection: LibraryCollection = .all
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var findRequest = 0
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    public init(model: ReaderModel, agent: LibraryAgent? = nil) {
        self.model = model
        _agent = State(initialValue: agent ?? LibraryAgent(reader: model))
    }

    public var body: some View {
        navigationSurface
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) {
                result in
                switch result {
                case .success(let urls): Task { await model.importURLs(urls) }
                case .failure(let error): model.message = error.localizedDescription
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            .sheet(isPresented: $showSearch) { SearchView(model: model) }
            .alert(
                "PaperReader",
                isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
            ) {
                Button("好") { model.message = nil }
            } message: {
                Text(model.message ?? "")
            }
            .task { await model.load() }
            .task(id: model.status) {
                guard model.loaded, model.status != "仅保存在此设备", !model.isImporting, model.translating.isEmpty else {
                    return
                }
                toast = model.status
                do {
                    try await Task.sleep(for: .seconds(4))
                    toast = nil
                } catch {}
            }
            .onChange(of: model.selectedPaperID) { _, id in if id != nil { preferredColumn = .detail } }
            .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
            .onReceive(timer) { _ in model.tick() }
    }

    private var navigationSurface: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $preferredColumn) {
            Group {
                if isReading {
                    ReaderNavigator(model: model, findRequest: findRequest) { preferredColumn = .detail }
                } else {
                    sidebar
                }
            }.navigationSplitViewColumnWidth(min: 210, ideal: 244, max: 320)
        } detail: {
            detailContent
        }
        .tint(ReaderTheme.accent)
        .background {
            Button("查找") {
                findRequest += 1
                if isReading {
                    columns = .all
                    preferredColumn = .sidebar
                }
            }.keyboardShortcut("f").hidden().accessibilityHidden(true)
        }
        .background {
            Button("导入 PDF") { showImporter = true }
                .keyboardShortcut("o").hidden().accessibilityHidden(true)
        }
        .overlay {
            if dragTarget {
                RoundedRectangle(cornerRadius: 18).fill(ReaderTheme.accent.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18).strokeBorder(
                            ReaderTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    )
                    .overlay {
                        Label("添加到书库", systemImage: "arrow.down.doc").font(.title2.weight(.medium)).padding(30)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }.padding(12).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return false }
            Task { await model.importURLs(pdfs) }
            return true
        } isTargeted: {
            dragTarget = $0
        }
    }

    private var detailContent: some View {
        GeometryReader { proxy in
            let inline = proxy.size.width >= 900
            HStack(spacing: 0) {
                workspaceContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showAgent && inline {
                    Divider()
                    agentPanel(inline: true).frame(width: 360)
                }
            }
            .sheet(
                isPresented: Binding(get: { showAgent && !inline }, set: { showAgent = $0 }),
                onDismiss: {
                    if pendingAgentSettings {
                        pendingAgentSettings = false
                        showSettings = true
                    }
                }
            ) {
                agentPanel(inline: false)
                    #if os(macOS)
                        .frame(width: 400, height: 650)
                    #else
                        .presentationSizing(.form)
                    #endif
            }
        }
        .background(ReaderTheme.canvas)
        .toolbar {
            ToolbarItem {
                Button {
                    showAgent.toggle()
                } label: {
                    Label("Agent", systemImage: "sparkle")
                }.help("书库 Agent").accessibilityLabel("书库 Agent")
                    .foregroundStyle(showAgent ? ReaderTheme.accent : ReaderTheme.muted)
                    .disabled(!model.loaded || model.loadFailure != nil)
            }
        }
        .overlay(alignment: .bottom) {
            if model.isImporting || !model.translating.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.status).font(.caption).lineLimit(1)
                }.padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule()).padding(18)
            } else if let toast {
                Label(toast, systemImage: "checkmark.circle.fill").font(.caption).lineLimit(2)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule()).padding(18).allowsHitTesting(false)
            }
        }
    }

    private func agentPanel(inline: Bool) -> some View {
        LibraryAgentView(
            agent: agent, model: model, draft: $agentDraft,
            openSettings: {
                if inline {
                    showSettings = true
                } else {
                    pendingAgentSettings = true
                    showAgent = false
                }
            },
            close: { showAgent = false },
            didNavigate: { if !inline { showAgent = false } })
    }

    private var workspaceContent: some View {
        Group {
            if let failure = model.loadFailure {
                ContentUnavailableView(
                    "无法打开书库", systemImage: "externaldrive.badge.exclamationmark", description: Text(failure))
            } else if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selectedSection == "calendar" {
                ReadingCalendarView(model: model)
            } else if model.selectedSection == "memory" {
                MemoryView(model: model)
            } else if model.paper != nil {
                ReaderView(model: model, libraryAgentPresented: $showAgent, openSettings: { showSettings = true })
            } else {
                LibraryWorkspaceView(
                    model: model, collection: $collection, findRequest: findRequest,
                    searchOnline: { showSearch = true })
            }
        }
    }

    private var isReading: Bool { model.selectedSection == "library" && model.paper != nil }

    private var recentPapers: [Paper] {
        model.state.papers.filter { model.workspace(for: $0.id).lastOpenedAt != nil }.sorted {
            (model.workspace(for: $0.id).lastOpenedAt ?? .distantPast)
                > (model.workspace(for: $1.id).lastOpenedAt ?? .distantPast)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "book.pages").foregroundStyle(ReaderTheme.accent)
                Text("PaperReader").font(.system(size: 19, weight: .medium, design: .serif))
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 28)
            VStack(spacing: 3) {
                ForEach(LibraryCollection.allCases) { item in
                    navigation(
                        item.title, icon: item.icon,
                        selected: model.selectedSection == "library" && collection == item,
                        count: model.state.papers.filter { item.includes(model.workspace(for: $0.id), for: $0) }.count
                    ) {
                        model.select(nil)
                        collection = item
                        preferredColumn = .detail
                    }
                }
                Divider().padding(.vertical, 14).padding(.horizontal, 10)
                navigation("阅读日历", icon: "calendar", selected: model.selectedSection == "calendar") {
                    model.endReading()
                    model.selectedSection = "calendar"
                    preferredColumn = .detail
                }
                navigation("研究记忆", icon: "sparkles", selected: model.selectedSection == "memory") {
                    model.endReading()
                    model.selectedSection = "memory"
                    preferredColumn = .detail
                }
            }.padding(.horizontal, 10)
            if !recentPapers.isEmpty {
                Text("最近打开").font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                    .padding(.horizontal, 22).padding(.top, 30).padding(.bottom, 12)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(recentPapers.prefix(8)) { paper in
                            Button {
                                model.select(paper.id)
                                preferredColumn = .detail
                            } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "doc.text").foregroundStyle(ReaderTheme.muted).padding(.top, 2)
                                    Text(paper.title).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 10)
                }
            }
            Spacer(minLength: 20)
            Button {
                showImporter = true
            } label: {
                Label("导入 PDF", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(ReaderTheme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).padding(.horizontal, 18)
            Button {
                showSettings = true
            } label: {
                Label("设置", systemImage: "slider.horizontal.3").font(.system(size: 12))
                    .foregroundStyle(ReaderTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22).contentShape(Rectangle())
            }.buttonStyle(.plain).keyboardShortcut(",")
        }.frame(maxHeight: .infinity).background(ReaderTheme.sidebar)
    }

    private func navigation(
        _ title: String, icon: String, selected: Bool, count: Int? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer()
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                }
            }.foregroundStyle(ReaderTheme.ink.opacity(selected ? 1 : 0.75))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(selected ? ReaderTheme.ink.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
