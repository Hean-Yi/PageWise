import PaperReaderKit
import SwiftUI

struct ReaderNavigator: View {
    @Bindable var model: ReaderModel
    let findRequest: Int
    let didNavigate: () -> Void
    @State private var searching = false
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var chosenID: String?
    @State private var initializedOutline = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var sourcePage: Int {
        if model.mode == "original" || model.paper?.canReflow == false { return model.visiblePage }
        return model.activePages.indices.contains(model.visiblePage)
            ? model.activePages[model.visiblePage].sourcePage : 0
    }

    private struct Chapter: Identifiable {
        let heading: PaperNavigationItem
        var children: [PaperNavigationItem] = []
        var id: String { heading.id }
    }

    private func chapters(from items: [PaperNavigationItem]) -> [Chapter] {
        var chapters: [Chapter] = []
        for item in items where item.isOutline {
            if item.depth == 0 {
                chapters.append(Chapter(heading: item))
            } else if item.depth == 1, !chapters.isEmpty {
                chapters[chapters.count - 1].children.append(item)
            }
        }
        return chapters
    }

    private var visibleIndex: Int { model.usesHTMLReading ? model.visiblePage : sourcePage }

    private func activeItem(in items: [PaperNavigationItem]) -> PaperNavigationItem? {
        let index = visibleIndex
        let sectionIndexes: [UUID: Int] =
            model.usesHTMLReading
            ? Dictionary(
                model.activePages.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first })
            : [:]
        func location(_ item: PaperNavigationItem) -> Int? {
            if let id = item.readingSectionID { return sectionIndexes[id] }
            return item.sourcePage
        }
        if let chosen = items.first(where: { $0.id == chosenID }), location(chosen) == index { return chosen }
        // A page can contain several section starts. Only show one current row.
        return items.first { location($0) == index }
            ?? items.last { (location($0) ?? .max) < index }
    }

    var body: some View {
        let items = model.displayedNavigationItems
        let groups = chapters(from: items)
        let active = model.presentedDocumentSummary == nil ? activeItem(in: items) : nil
        let expandable = Set(groups.filter { !$0.children.isEmpty }.map(\.id))
        let pageList = groups.isEmpty && !items.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            #if os(iOS)
                if horizontalSizeClass == .compact {
                    Button {
                        model.returnFromReader()
                        didNavigate()
                    } label: {
                        Label(model.readerOrigin.title, systemImage: "arrow.left")
                    }.buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 12)
                }
            #endif
            HStack {
                Text(searching ? "文内查找" : (pageList ? "页码" : "目录"))
                    .font(ReaderTheme.editorial(21)).accessibilityAddTraits(.isHeader)
                    .contentTransition(.opacity)
                Spacer()
                if !searching, !expandable.isEmpty {
                    let allOpen = expandable.isSubset(of: expanded)
                    Button {
                        withAnimation(ReaderMotion.disclosure(reduceMotion)) { expanded = allOpen ? [] : expandable }
                    } label: {
                        Image(systemName: "chevron.down.2")
                            .rotationEffect(.degrees(allOpen ? 180 : 0))
                            .frame(minWidth: 28, minHeight: 32)
                    }
                    .buttonStyle(.borderless).foregroundStyle(ReaderTheme.muted)
                    .help(allOpen ? "收起全部章节" : "展开全部章节")
                    .accessibilityLabel(allOpen ? "收起全部章节" : "展开全部章节")
                }
                Button {
                    searching.toggle()
                    if !searching { searchFocused = false }
                } label: {
                    Label(
                        searching ? "返回目录" : "查找正文或译文",
                        systemImage: searching ? "list.bullet.indent" : "magnifyingglass"
                    ).labelStyle(.iconOnly).frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.borderless).foregroundStyle(ReaderTheme.muted)
                .help(searching ? "返回目录" : "文内查找（⌘F）")
            }
            .padding(.horizontal, 18).frame(height: 56)
            .animation(ReaderMotion.feedback(reduceMotion), value: searching)
            outline(groups, items: items, active: active)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(!searching)
                .accessibilityHidden(searching)
                .overlay {
                    ZStack {
                        if searching {
                            search.background(ReaderTheme.sidebar)
                                .onAppear { searchFocused = true }
                                .transition(.opacity)
                        }
                    }
                    .animation(ReaderMotion.disclosure(reduceMotion), value: searching)
                    .allowsHitTesting(searching)
                    .accessibilityHidden(!searching)
                }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(ReaderTheme.sidebar)
            .task(id: model.navigationDocumentID) { await model.loadNavigation() }
            .onChange(of: findRequest) { _, _ in
                searching = true
                searchFocused = true
            }
            .onChange(of: model.selectedPaperID) { _, _ in
                query = ""
                searching = false
                chosenID = nil
                expanded = []
                initializedOutline = false
            }
    }

    private func outline(_ groups: [Chapter], items: [PaperNavigationItem], active: PaperNavigationItem?) -> some View {
        let current = groups.first { group in group.id == active?.id || group.children.contains { $0.id == active?.id }
        }
        return ScrollViewReader { scroll in
            ScrollView {
                if model.navigationLoading && items.isEmpty {
                    ProgressView().controlSize(.small).padding()
                } else if items.isEmpty {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(ReaderTheme.muted)
                        .padding().accessibilityLabel("尚无章节标题")
                } else if groups.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                        ForEach(items) { item in
                            Button {
                                navigate(item)
                            } label: {
                                Text("\(item.sourcePage + 1)").monospacedDigit()
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(
                                        active?.id == item.id ? ReaderTheme.elevated : .clear,
                                        in: RoundedRectangle(cornerRadius: 7)
                                    ).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).id(item.id).help(item.title).accessibilityLabel(item.title)
                            .accessibilityAddTraits(active?.id == item.id ? .isSelected : [])
                        }
                    }.padding(.horizontal, 12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(groups) { group in
                            let open = expanded.contains(group.id)
                            let selected = active?.id == group.id || (!open && current?.id == group.id)
                            HStack(spacing: 0) {
                                if group.children.isEmpty {
                                    Color.clear.frame(width: 24)
                                } else {
                                    Button {
                                        withAnimation(ReaderMotion.disclosure(reduceMotion)) {
                                            if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
                                        }
                                    } label: {
                                        Image(systemName: "chevron.forward")
                                            .font(.system(size: 10, weight: .bold))
                                            .rotationEffect(
                                                .degrees(open ? (layoutDirection == .rightToLeft ? -90 : 90) : 0)
                                            )
                                            .foregroundStyle(open ? ReaderTheme.accent : ReaderTheme.muted)
                                            .frame(width: 24, height: 34).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel((open ? "收起 " : "展开 ") + group.heading.title)
                                }
                                chapterLink(group.heading, selected: selected)
                            }
                            .background(selected ? ReaderTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .id(group.id)
                            if open {
                                ForEach(group.children) { child in
                                    chapterLink(child, selected: child.id == active?.id)
                                        .padding(.leading, 11)
                                        .overlay(alignment: .leading) {
                                            Rectangle().fill(ReaderTheme.line).frame(width: 1)
                                        }
                                        .padding(.leading, 26)
                                        .background(
                                            child.id == active?.id ? ReaderTheme.elevated : .clear,
                                            in: RoundedRectangle(cornerRadius: 7)
                                        )
                                        .id(child.id)
                                        .transition(.opacity)
                                }
                            }
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 12)
                }
                if let summary = model.currentDocumentSummary {
                    Divider().padding(.horizontal, 16)
                    Button {
                        model.openReadingNote(summary)
                        didNavigate()
                    } label: {
                        Label("文末总结", systemImage: "doc.append")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .background(
                            model.presentedSummaryID == summary.id ? ReaderTheme.elevated : .clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .padding(.horizontal, 8)
                }
            }
            .onChange(of: groups.first?.id, initial: true) { _, first in
                if first != nil, !initializedOutline {
                    initializedOutline = true
                    if let current, !current.children.isEmpty { expanded.insert(current.id) }
                    if let current { scroll.scrollTo(current.id) }
                }
            }
            .onChange(of: visibleIndex) { _, _ in
                guard let active else { return }
                scroll.scrollTo(current.flatMap { expanded.contains($0.id) ? nil : $0.id } ?? active.id)
            }
        }
    }

    private func chapterLink(_ item: PaperNavigationItem, selected: Bool) -> some View {
        Button {
            navigate(item)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(item.depth == 0 ? .body.weight(.semibold) : .callout)
                    .foregroundStyle(item.depth == 0 || selected ? ReaderTheme.ink : ReaderTheme.muted)
                    .multilineTextAlignment(.leading).lineLimit(3)
                Spacer(minLength: 0)
                if item.sourcePage >= 0 {
                    Text("\(item.sourcePage + 1)").font(.caption.monospacedDigit()).foregroundStyle(ReaderTheme.muted)
                }
            }
            .padding(.trailing, 9).padding(.vertical, item.depth == 0 ? 9 : 6)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(item.title)
        .accessibilityLabel(item.sourcePage >= 0 ? "\(item.title)，原文第 \(item.sourcePage + 1) 页" : item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func navigate(_ item: PaperNavigationItem) {
        chosenID = item.id
        model.navigate(to: item)
        didNavigate()
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.muted)
                TextField("查找正文或译文", text: $query).textFieldStyle(.plain).focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted).help("清除文内查找").accessibilityLabel("清除文内查找")
                }
            }.font(.system(size: 12)).padding(10).background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ReaderTheme.line)).padding(14)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if model.paper?.blocks.isEmpty == true {
                    Label("没有可检索文字", systemImage: "doc.questionmark").font(.caption)
                        .foregroundStyle(ReaderTheme.muted).padding(22)
                }
            } else {
                let results = model.searchInPaper(query)
                Text(
                    results.isEmpty
                        ? "没有找到匹配"
                        : "\(results.count == PaperTextSearch.maximumResults ? "前 " : "")\(results.count) 个匹配段落"
                )
                .font(.system(size: 11)).foregroundStyle(ReaderTheme.muted).padding(.horizontal, 22).padding(
                    .bottom, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(results) { result in
                            Button {
                                model.navigate(to: result)
                                didNavigate()
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(
                                            result.sourcePage >= 0 ? "原文第 \(result.sourcePage + 1) 页" : "重排内容 · 原文页码未核对"
                                        )
                                        Spacer()
                                        Text(result.isTranslation ? "译文" : "原文")
                                    }.font(.system(size: 10)).foregroundStyle(ReaderTheme.accent)
                                    Text(emphasized(result.text)).font(.system(size: 12)).lineLimit(5)
                                        .lineSpacing(3).multilineTextAlignment(.leading)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(ReaderTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 10)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func emphasized(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty, let range = value.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            value[range].foregroundColor = ReaderTheme.accent
            value[range].font = .system(size: 12, weight: .semibold)
        }
        return value
    }
}
