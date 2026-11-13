import PaperReaderKit
import SwiftUI

struct LibraryWorkspaceView: View {
    @Bindable var model: ReaderModel
    @Binding var collection: LibraryCollection
    let findRequest: Int
    let importPDF: () -> Void
    let searchOnline: () -> Void
    @State private var query = ""
    @State private var sort: LibrarySort = .recent
    @AppStorage("libraryPresentation") private var presentation = "list"
    @FocusState private var searchFocused: Bool

    private var papers: [Paper] {
        LibraryQuery.papers(in: model.state, collection: collection, query: query, sort: sort)
    }
    private var recent: Paper? {
        LibraryQuery.papers(in: model.state, collection: .reading).first {
            model.workspace(for: $0.id).position != nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 700
            VStack(alignment: .leading, spacing: 0) {
                header(compact: compact)
                if model.state.papers.isEmpty {
                    welcome
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            if collection == .all && query.isEmpty, let recent {
                                continueReading(recent)
                            }
                            VStack(spacing: 0) {
                                filters
                                if papers.isEmpty {
                                    ContentUnavailableView {
                                        Label(query.isEmpty ? "这里还没有论文" : "没有找到论文", systemImage: "magnifyingglass")
                                    } actions: {
                                        if !query.isEmpty { Button("清除搜索") { query = "" } }
                                    }.frame(minHeight: 240)
                                } else if presentation == "grid" {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], spacing: 18) {
                                        ForEach(papers) { paper in card(paper) }
                                    }.padding(.top, 18)
                                } else {
                                    paperList(compact: compact)
                                }
                            }
                        }.padding(.horizontal, compact ? 24 : 40).padding(.bottom, 40)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: findRequest) { _, _ in searchFocused = true }
    }

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(collection.title).font(.system(size: 30, weight: .regular, design: .serif))
                Text("\(papers.count)").font(.system(size: 13)).foregroundStyle(ReaderTheme.muted)
                Spacer()
                Menu {
                    Button("导入 PDF…", systemImage: "doc.badge.plus", action: importPDF)
                    Button("在线查找论文…", systemImage: "globe", action: searchOnline)
                } label: {
                    Label("添加论文", systemImage: "plus").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ReaderTheme.line))
                }.menuStyle(.borderlessButton).fixedSize()
            }
            if !model.state.papers.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.muted)
                    TextField("搜索书库", text: $query).textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityLabel("搜索书库")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted).help("清除搜索").accessibilityLabel("清除搜索")
                    } else {
                        Text("⌘ F").font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                    }
                }.font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 12)
                    .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ReaderTheme.line))
            }
        }.padding(.horizontal, compact ? 24 : 40).padding(.top, 32).padding(.bottom, 26)
    }

    private func continueReading(_ paper: Paper) -> some View {
        Button {
            model.select(paper.id)
        } label: {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("继续阅读", systemImage: "book.pages").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ReaderTheme.accent)
                    Text(paper.title).font(.system(size: 23, weight: .regular, design: .serif))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let position = model.workspace(for: paper.id).position {
                        Text("\(readingModeTitle(position.mode)) · 第 \(position.pageIndex + 1) 页")
                            .font(.system(size: 12)).foregroundStyle(ReaderTheme.muted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 18, weight: .light))
                    .foregroundStyle(ReaderTheme.accent).padding(14)
                    .background(ReaderTheme.surface.opacity(0.7), in: Circle())
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                .background(ReaderTheme.elevated, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityLabel("继续阅读 \(paper.title)")
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Text(query.isEmpty ? "论文" : "搜索结果").font(.system(size: 12, weight: .medium))
                .foregroundStyle(ReaderTheme.muted)
            Spacer()
            Menu {
                Picker("排序", selection: $sort) {
                    ForEach(LibrarySort.allCases) { item in Text(item.title).tag(item) }
                }
            } label: {
                Label(sort.title, systemImage: "arrow.up.arrow.down").font(.system(size: 11))
            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(ReaderTheme.muted)
            Divider().frame(height: 16)
            Picker("书库视图", selection: $presentation) {
                Image(systemName: "list.bullet").tag("list").help("列表视图").accessibilityLabel("列表视图")
                Image(systemName: "square.grid.2x2").tag("grid").help("卡片视图").accessibilityLabel("卡片视图")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 64)
        }.padding(.bottom, 12)
    }

    private func paperList(compact: Bool) -> some View {
        LazyVStack(spacing: 0) {
            Divider()
            ForEach(papers) { paper in
                HStack(spacing: 14) {
                    Button {
                        model.select(paper.id)
                    } label: {
                        HStack(spacing: 16) {
                            PaperGlyph().frame(width: 34, height: 44)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(paper.title).font(.system(size: 15, weight: .medium))
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                HStack(spacing: 8) {
                                    Text("\(paper.pageCount) 页")
                                    Text(paper.canReflow ? "重排" : "PDF")
                                    if paper.translatedBlockCount > 0 {
                                        Label("双语", systemImage: "translate")
                                    }
                                }.font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                            }
                            Spacer(minLength: 0)
                            if !compact {
                                if let date = model.workspace(for: paper.id).lastOpenedAt {
                                    Text(
                                        date.formatted(
                                            .dateTime.year().month(.twoDigits).day(.twoDigits).locale(
                                                Locale(identifier: "zh_CN")))
                                    )
                                    .font(.system(size: 11)).foregroundStyle(ReaderTheme.muted).help("最近打开")
                                }
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    statusMenu(paper).frame(width: 62)
                    favorite(paper)
                }.padding(.vertical, 18)
                    .contextMenu { paperActions(paper) }
                Divider()
            }
        }
    }

    private func card(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.select(paper.id)
            } label: {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("PDF").font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(ReaderTheme.muted)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(ReaderTheme.muted)
                    }
                    Text(paper.title).font(.system(size: 21, weight: .regular, design: .serif))
                        .lineLimit(4).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    HStack {
                        Text("\(paper.pageCount) 页")
                        Spacer()
                        Text(paper.canReflow ? "重排阅读" : "原始 PDF")
                    }.font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ReaderTheme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
            HStack {
                statusMenu(paper)
                Spacer()
                favorite(paper)
            }.padding(.horizontal, 4).padding(.top, 12)
        }.contextMenu { paperActions(paper) }
    }

    private func favorite(_ paper: Paper) -> some View {
        let saved = model.workspace(for: paper.id).isFavorite
        return Button {
            model.toggleFavorite(paper.id)
        } label: {
            Image(systemName: saved ? "star.fill" : "star").font(.system(size: 13))
                .foregroundStyle(saved ? ReaderTheme.accent : ReaderTheme.muted.opacity(0.6))
                .frame(width: 28, height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).help(saved ? "取消收藏" : "收藏")
            .accessibilityLabel("\(saved ? "取消收藏" : "收藏") \(paper.title)")
    }

    private func statusMenu(_ paper: Paper) -> some View {
        let status = model.workspace(for: paper.id).status
        return Menu {
            ForEach([PaperReadingStatus.unread, .reading, .finished], id: \.self) { value in
                Button {
                    model.setReadingStatus(value, for: paper.id)
                } label: {
                    if status == value { Label(value.title, systemImage: "checkmark") } else { Text(value.title) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(status == .reading ? ReaderTheme.accent : ReaderTheme.muted.opacity(0.45))
                    .frame(width: 5, height: 5)
                Text(status.title).font(.system(size: 11))
            }.foregroundStyle(ReaderTheme.muted)
        }.menuStyle(.borderlessButton).fixedSize().help("阅读状态")
            .accessibilityLabel("阅读状态：\(status.title)，\(paper.title)")
    }

    @ViewBuilder private func paperActions(_ paper: Paper) -> some View {
        Button("打开论文") { model.select(paper.id) }
        Button(model.workspace(for: paper.id).isFavorite ? "取消收藏" : "收藏") { model.toggleFavorite(paper.id) }
        Divider()
        ForEach([PaperReadingStatus.unread, .reading, .finished], id: \.self) { value in
            Button("标记为\(value.title)") { model.setReadingStatus(value, for: paper.id) }
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            PaperIllustration().padding(.bottom, 20)
            Text("从一篇论文开始").font(.system(size: 29, weight: .regular, design: .serif)).padding(.bottom, 12)
            Text("拖入 PDF，或按标题查找").font(.subheadline).foregroundStyle(ReaderTheme.muted).padding(.bottom, 28)
            HStack(spacing: 12) {
                Button(action: importPDF) { Label("导入 PDF", systemImage: "plus") }.buttonStyle(.borderedProminent)
                Button(action: searchOnline) { Label("在线查找", systemImage: "globe") }.buttonStyle(.bordered)
            }.controlSize(.large)
            Button("试读示例") { Task { await model.addDemo() } }
                .buttonStyle(.plain).font(.caption).foregroundStyle(ReaderTheme.muted).padding(.top, 24)
            Spacer(minLength: 40)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PaperGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(ReaderTheme.accent.opacity(0.8)).frame(width: 10, height: 3).padding(.bottom, 3)
            ForEach(0..<3) { index in
                Rectangle().fill(ReaderTheme.muted.opacity(0.3)).frame(width: index == 2 ? 12 : 18, height: 1)
            }
            Spacer(minLength: 0)
        }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ReaderTheme.line)).accessibilityHidden(true)
    }
}

func readingModeTitle(_ mode: String) -> String {
    switch mode {
    case "original": "原文"
    case "translated": "双语"
    default: "重排"
    }
}
