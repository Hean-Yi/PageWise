import PaperReaderKit
import SwiftUI

struct LibraryWorkspaceView: View {
    @Bindable var model: ReaderModel
    @Binding var collection: LibraryCollection
    let findRequest: Int
    let searchOnline: () -> Void
    @State private var query = ""
    @State private var sort: LibrarySort = .recent
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
            let inset: CGFloat = geometry.size.width < 650 ? 28 : 44
            let available = max(150, geometry.size.width - inset * 2)
            let count = max(1, Int((available + 36) / 226))
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 150, maximum: 236), spacing: 36, alignment: .top), count: count)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(compact: geometry.size.width < 650)
                    Divider().padding(.top, 20).padding(.bottom, 26)
                    if collection == .all && query.isEmpty, let recent {
                        continueReading(recent).padding(.bottom, 30)
                    }
                    filters.padding(.bottom, 24)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 32) {
                        if collection != .reading && collection != .finished {
                            AddPaperCover(action: searchOnline)
                        }
                        ForEach(papers) { paper in BookshelfItem(model: model, paper: paper) }
                    }.padding(.top, 5)
                    if model.state.papers.isEmpty && collection == .all {
                        HStack(spacing: 14) {
                            Text("也可以拖入 PDF").foregroundStyle(ReaderTheme.muted)
                            Button("试读示例") { Task { await model.addDemo() } }
                                .buttonStyle(.plain).foregroundStyle(ReaderTheme.accent)
                        }.font(.system(size: 12)).padding(.top, 22)
                    } else if papers.isEmpty {
                        HStack {
                            Text(query.isEmpty ? "这个书架还没有论文" : "没有匹配的论文")
                                .foregroundStyle(ReaderTheme.muted)
                            if !query.isEmpty { Button("清除搜索") { query = "" }.buttonStyle(.plain) }
                        }.font(.system(size: 12)).padding(.top, 22)
                    }
                }.padding(.horizontal, inset).padding(.top, 28).padding(.bottom, 44)
            }
        }.onChange(of: findRequest) { _, _ in searchFocused = true }
    }

    @ViewBuilder private func header(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 20) {
                heading
                searchField
            }
        } else {
            HStack(alignment: .center) {
                heading
                Spacer(minLength: 24)
                searchField.frame(width: 250)
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(collection.title).font(.system(size: 28, weight: .semibold))
            Text("\(papers.count)").font(.system(size: 12)).foregroundStyle(ReaderTheme.muted)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.muted)
            TextField("搜索书库", text: $query).textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("搜索书库")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                .help("清除搜索").accessibilityLabel("清除搜索")
            } else {
                #if os(macOS)
                    Text("⌘ F").font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                #endif
            }
        }.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 10)
            .background(ReaderTheme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func continueReading(_ paper: Paper) -> some View {
        Button {
            model.select(paper.id)
        } label: {
            HStack(spacing: 18) {
                BookCoverView(paper: paper).frame(width: 43)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 3)
                VStack(alignment: .leading, spacing: 7) {
                    Text("继续阅读").font(.system(size: 10, weight: .medium)).foregroundStyle(ReaderTheme.accent)
                    Text(paper.title).font(.system(size: 18, weight: .medium, design: .serif))
                        .lineLimit(1).multilineTextAlignment(.leading)
                    if let position = model.workspace(for: paper.id).position {
                        Text("\(readingModeTitle(position.mode)) · 第 \(position.pageIndex + 1) 页")
                            .font(.system(size: 11)).foregroundStyle(ReaderTheme.muted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 15, weight: .regular))
                    .foregroundStyle(ReaderTheme.accent).frame(width: 34, height: 34)
                    .background(ReaderTheme.surface.opacity(0.7), in: Circle())
            }.padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReaderTheme.elevated.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel("继续阅读 \(paper.title)")
    }

    private var filters: some View {
        HStack {
            Text(query.isEmpty ? "书架" : "搜索结果").font(.system(size: 12, weight: .medium))
                .foregroundStyle(ReaderTheme.muted)
            Spacer()
            Menu {
                Picker("排序", selection: $sort) {
                    ForEach(LibrarySort.allCases) { item in Text(item.title).tag(item) }
                }
            } label: {
                Label(sort.title, systemImage: "arrow.up.arrow.down").font(.system(size: 11))
            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(ReaderTheme.muted)
        }
    }
}

func readingModeTitle(_ mode: String) -> String {
    switch mode {
    case "original": "原文"
    case "translated": "双语"
    default: "重排"
    }
}
