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
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    public init(model: ReaderModel) { self.model = model }

    public var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "book.closed.fill").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PaperReader").font(.headline)
                        Text("READ · THINK · CONNECT").font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(20)
                List {
                    Section {
                        Button {
                            model.endReading()
                            model.selectedSection = "library"
                            model.beginReading()
                            preferredColumn = .detail
                        } label: {
                            Label("论文书库", systemImage: "books.vertical")
                        }
                        Button {
                            model.endReading()
                            model.selectedSection = "calendar"
                            preferredColumn = .detail
                        } label: {
                            Label("阅读日历", systemImage: "calendar")
                        }
                        Button {
                            model.endReading()
                            model.selectedSection = "memory"
                            preferredColumn = .detail
                        } label: {
                            Label("研究记忆", systemImage: "brain.head.profile")
                        }
                    }
                    Section("论文 · \(model.state.papers.count)") {
                        ForEach(model.state.papers) { paper in
                            Button {
                                model.select(paper.id)
                                preferredColumn = .detail
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: paper.canReflow ? "doc.richtext" : "doc").foregroundStyle(.teal)
                                        .padding(.top, 3)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(paper.title).lineLimit(2).foregroundStyle(.primary)
                                        Text(
                                            "\(paper.pageCount) 页 · \(paper.translatedBlockCount > 0 ? "已译 \(paper.translatedBlockCount)/\(paper.blocks.count) 段" : "本地文献")"
                                        )
                                        .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 5)
                            }.listRowBackground(
                                paper.id == model.selectedPaperID && model.selectedSection == "library"
                                    ? Color.teal.opacity(0.1) : Color.clear)
                        }
                    }
                }.listStyle(.sidebar).buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 9) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("模型与笔记设置", systemImage: "slider.horizontal.3")
                    }
                    Label("仅保存在此设备", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            Group {
                if let failure = model.loadFailure {
                    ContentUnavailableView(
                        "书库无法读取", systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(failure + " 原文件已保留，未创建替代书库。"))
                } else if !model.loaded {
                    ProgressView("正在打开书库…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.selectedSection == "calendar" {
                    ReadingCalendarView(model: model)
                } else if model.selectedSection == "memory" {
                    MemoryView(model: model)
                } else if model.paper != nil {
                    ReaderView(model: model)
                } else {
                    welcome
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showSearch = true
                    } label: {
                        Label("查找论文", systemImage: "magnifyingglass")
                    }.help("按论文标题查找 arXiv")
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入 PDF", systemImage: "plus")
                    }.keyboardShortcut("o")
                    Button {
                        showSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
        }
        .tint(.teal)
        .overlay {
            if dragTarget {
                RoundedRectangle(cornerRadius: 18).fill(.teal.opacity(0.12)).overlay {
                    Label("松开以导入 PDF 并重排", systemImage: "square.and.arrow.down").font(.title2.bold()).padding(30)
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
        .onChange(of: model.selectedPaperID) { _, id in if id != nil { preferredColumn = .detail } }
        .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
        .onReceive(timer) { _ in model.tick() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                if model.isImporting || !model.translating.isEmpty { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).lineLimit(1)
                Spacer()
                Text("LOCAL FIRST").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(systemName: "text.book.closed").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(.teal)
            VStack(spacing: 10) {
                Text("让论文，读起来更轻松。").font(.system(size: 28, weight: .medium, design: .serif))
                Text("拖入 PDF，重新排版。\n在原文与译文之间思考，把理解留在纸面上。")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            }
            HStack(spacing: 12) {
                Button("导入 PDF") { showImporter = true }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("查找论文") { showSearch = true }.buttonStyle(.bordered).controlSize(.large)
            }
            Button("先试读一篇本地示例") { Task { await model.addDemo() } }.font(.callout)
            HStack(spacing: 24) {
                Label("双语固定页", systemImage: "character.book.closed")
                Label("划线与问答", systemImage: "highlighter")
                Label("Obsidian 笔记", systemImage: "square.and.pencil")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 14)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}
