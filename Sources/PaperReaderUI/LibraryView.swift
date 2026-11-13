import PaperReaderKit
import SwiftUI
import UniformTypeIdentifiers

public struct LibraryView: View {
    @Bindable var model: ReaderModel
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var dragTarget = false
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var toast: String?
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    public init(model: ReaderModel) { self.model = model }

    public var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 290)
        } detail: {
            detailContent
        }
        .tint(ReaderTheme.accent)
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
            "PaperReader", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) {
            Button("好") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .task { await model.load() }
        .task(id: model.status) {
            guard model.loaded, model.status != "仅保存在此设备", !model.isImporting, model.translating.isEmpty else { return }
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

    private var detailContent: some View {
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
                ReaderView(model: model, openSettings: { showSettings = true })
            } else {
                library
            }
        }
        .background(ReaderTheme.canvas)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("导入 PDF…", systemImage: "doc.badge.plus") { showImporter = true }.keyboardShortcut("o")
                    Button("查找论文…", systemImage: "magnifyingglass") { showSearch = true }
                } label: {
                    Image(systemName: "plus")
                }.help("添加论文")
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed.fill").font(.title3).foregroundStyle(ReaderTheme.accent)
                Text("PaperReader").font(.system(size: 17, weight: .semibold, design: .rounded))
            }.padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 32)
            VStack(spacing: 5) {
                navigation("书库", icon: "books.vertical", section: "library")
                navigation("阅读日历", icon: "calendar", section: "calendar")
                navigation("研究记忆", icon: "sparkles", section: "memory")
            }.padding(.horizontal, 12)
            if !model.state.papers.isEmpty {
                Text("最近阅读").font(.caption).foregroundStyle(ReaderTheme.muted)
                    .padding(.horizontal, 22).padding(.top, 32).padding(.bottom, 12)
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(model.state.papers.prefix(12)) { paper in
                            Button {
                                model.select(paper.id)
                                preferredColumn = .detail
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(
                                        ReaderTheme.muted
                                    ).padding(.top, 2)
                                    Text(paper.title).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(
                                        .leading)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 12).padding(.vertical, 10).frame(
                                    maxWidth: .infinity, alignment: .leading
                                )
                                .background(
                                    model.selectedPaperID == paper.id && model.selectedSection == "library"
                                        ? ReaderTheme.accent.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 10)
                }
            }
            Spacer(minLength: 20)
            Divider().padding(.horizontal, 20)
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                    Text("设置")
                    Spacer()
                    Image(systemName: "internaldrive").font(.caption).foregroundStyle(ReaderTheme.muted).help("保存在此设备")
                }.font(.system(size: 13)).foregroundStyle(ReaderTheme.muted).padding(22).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.frame(maxHeight: .infinity).background(ReaderTheme.sidebar)
    }

    private func navigation(_ title: String, icon: String, section: String) -> some View {
        let selected = model.selectedSection == section && (section != "library" || model.selectedPaperID == nil)
        return Button {
            model.endReading()
            if section == "library" { model.select(nil) }
            model.selectedSection = section
            preferredColumn = .detail
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if section == "library" && !model.state.papers.isEmpty {
                    Text("\(model.state.papers.count)").font(.caption).foregroundStyle(ReaderTheme.muted)
                }
            }.foregroundStyle(selected ? ReaderTheme.accent : ReaderTheme.ink.opacity(0.75))
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(selected ? ReaderTheme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("书库").font(.system(size: 30, weight: .semibold))
                Text("\(model.state.papers.count) 篇").font(.subheadline).foregroundStyle(ReaderTheme.muted)
                Spacer()
                if !model.state.papers.isEmpty {
                    Button {
                        showSearch = true
                    } label: {
                        Label("查找", systemImage: "magnifyingglass")
                    }.buttonStyle(.borderless)
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入 PDF", systemImage: "plus")
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 24)
            if model.state.papers.isEmpty {
                welcome
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 20)], alignment: .leading,
                        spacing: 20
                    ) {
                        ForEach(model.state.papers) { paper in
                            Button {
                                model.select(paper.id)
                            } label: {
                                paperCard(paper)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 40).padding(.bottom, 40)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func paperCard(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "doc.richtext").font(.system(size: 24, weight: .light)).foregroundStyle(
                    ReaderTheme.accent
                )
                .frame(width: 52, height: 64).background(
                    ReaderTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(ReaderTheme.muted.opacity(0.5))
            }
            Text(paper.title).font(.system(size: 17, weight: .medium, design: .serif)).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading).multilineTextAlignment(.leading)
            HStack(spacing: 8) {
                Text("\(paper.pageCount) 页")
                Circle().fill(ReaderTheme.muted.opacity(0.5)).frame(width: 3, height: 3)
                Text(paper.canReflow ? "可重排" : "PDF")
                Spacer()
                if paper.translatedBlockCount > 0 { Image(systemName: "translate").foregroundStyle(ReaderTheme.accent) }
            }.font(.caption).foregroundStyle(ReaderTheme.muted)
        }.padding(22).background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ReaderTheme.line))
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            PaperIllustration().padding(.bottom, 24)
            Text("从一篇论文开始").font(.system(size: 26, weight: .medium, design: .serif)).padding(.bottom, 10)
            Text("拖入 PDF，或按标题查找").font(.subheadline).foregroundStyle(ReaderTheme.muted).padding(.bottom, 28)
            HStack(spacing: 12) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入 PDF", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button {
                    showSearch = true
                } label: {
                    Label("查找论文", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            Button("试读示例") { Task { await model.addDemo() } }
                .buttonStyle(.plain).font(.caption).foregroundStyle(ReaderTheme.muted).padding(.top, 24)
            Spacer(minLength: 40)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
