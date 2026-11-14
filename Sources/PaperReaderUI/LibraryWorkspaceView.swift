import PaperReaderKit
import SwiftUI

struct LibraryWorkspaceView: View {
    @Bindable var model: ReaderModel
    @Binding var collection: LibraryCollection
    @Binding var selectedShelfID: UUID?
    @Bindable var onlineSearch: OnlinePaperSearch
    let findRequest: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var arrangement = CoverArrangement()
    private var sort: LibrarySort { model.state.preferredSort }
    @FocusState private var searchFocused: Bool

    private var papers: [Paper] {
        LibraryQuery.papers(in: model.state, collection: collection, query: query, sort: sort).filter {
            collection != .all || (selectedShelfID == nil && !query.isEmpty)
                || model.state.shelfID(for: $0.id) == selectedShelfID
        }
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
                    if collection == .all && selectedShelfID == nil && query.isEmpty, let recent {
                        continueReading(recent).padding(.bottom, 30)
                    }
                    if collection == .all {
                        TopicShelvesView(
                            model: model, selectedShelfID: $selectedShelfID, dragActive: arrangement.sourceID != nil
                        ).padding(.bottom, 24)
                    }
                    if onlineSearch.isExpanded {
                        SearchView(search: onlineSearch, targetName: onlineTargetName)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                            .padding(.bottom, 26)
                    }
                    filters.padding(.bottom, 24)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 32) {
                        if collection != .reading && collection != .finished {
                            AddPaperCover { onlineSearch.open(shelfID: collection == .all ? selectedShelfID : nil) }
                        }
                        ForEach(papers) { paper in
                            bookshelfItem(
                                paper, columns: count,
                                width: min(236, (available - CGFloat(count - 1) * 36) / CGFloat(count)))
                        }
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
        }.onChange(of: query) { _, _ in arrangement.end() }
            .onChange(of: collection) { _, _ in arrangement.end() }
            .onChange(of: selectedShelfID) { _, _ in arrangement.end() }
            .onChange(of: sort) { _, _ in arrangement.end() }
            .onDisappear { arrangement.end() }
            .onChange(of: findRequest) { _, _ in searchFocused = true }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: onlineSearch.isExpanded)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedShelfID)
            .onChange(of: onlineSearch.isExpanded) { _, expanded in if expanded { searchFocused = false } }
            .onChange(of: model.state.shelves) { _, shelves in
                if let selectedShelfID, !shelves.contains(where: { $0.id == selectedShelfID }) {
                    self.selectedShelfID = nil
                }
            }
    }

    private func bookshelfItem(_ paper: Paper, columns: Int, width: CGFloat) -> some View {
        let ids = papers.map(\.id)
        let index = ids.firstIndex(of: paper.id) ?? 0
        let destination = index + arrangement.offset(for: paper.id)
        // Add-cover occupies the first grid cell but is never a reorder destination.
        let leading = collection != .reading && collection != .finished ? 1 : 0
        let from = index + leading
        let to = destination + leading
        let offset = CGSize(
            width: CGFloat(to % columns - from % columns) * (width + 36),
            height: CGFloat(to / columns - from / columns) * (width / 0.70 + 77))
        return BookshelfItem(
            model: model, paper: paper, lifted: arrangement.sourceID == paper.id,
            arrangementOffset: offset,
            beginDrag: {
                arrangement.begin(paper.id, visible: ids, state: model.state, unfinishedFirst: collection == .all)
            },
            endDrag: { arrangement.end() },
            acceptsDrop: { arrangement.accepts($0, at: paper.id) },
            hoverDrop: { arrangement.hover($0, at: paper.id) },
            receiveDrop: { id in
                guard arrangement.accepts(id, at: paper.id), arrangement.reserveDrop() else { return false }
                Task { await arrangement.commit(model: model) }
                return true
            },
            moveEarlier: orderAction(paper.id, delta: -1),
            moveLater: orderAction(paper.id, delta: 1)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: arrangement.preview)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: arrangement.sourceID)
    }

    private func orderAction(_ id: UUID, delta: Int) -> (() -> Void)? {
        let ids = papers.map(\.id)
        guard !arrangement.committing, let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else {
            return nil
        }
        let destination = ids[index + delta]
        if collection == .all {
            let finished = Set(LibraryQuery.papers(in: model.state, collection: .finished).map(\.id))
            guard finished.contains(id) == finished.contains(destination) else { return nil }
        }
        return {
            var reordered = ids
            reordered.swapAt(index, index + delta)
            Task { await model.arrangePapers(original: ids, reordered: reordered, unfinishedFirst: collection == .all) }
        }
    }

    private var onlineTargetName: String {
        guard let id = onlineSearch.targetShelfID else { return "未分类论文" }
        return model.state.shelves.first { $0.id == id }?.name ?? "原书架已删除"
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
            Text(
                "\(collection == .all && query.isEmpty ? model.state.papers.count : papers.count)"
            ).font(.system(size: 12)).foregroundStyle(ReaderTheme.muted)
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
            if !query.isEmpty {
                Text("搜索结果").font(.system(size: 12, weight: .medium)).foregroundStyle(ReaderTheme.muted)
            }
            Spacer()
            Menu {
                Picker(
                    "排序",
                    selection: Binding(
                        get: { sort },
                        set: { value in
                            Task { await model.selectLibrarySort(value) }
                        })
                ) {
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
