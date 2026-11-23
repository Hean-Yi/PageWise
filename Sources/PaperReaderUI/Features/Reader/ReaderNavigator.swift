import PaperReaderKit
import SwiftUI

struct ReaderNavigator: View {
    @Bindable var model: ReaderModel
    let findRequest: Int
    let didNavigate: () -> Void
    @State private var tab = "outline"
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var sourcePage: Int {
        if model.mode == "original" || model.paper?.canReflow == false { return model.visiblePage }
        return model.activePages.indices.contains(model.visiblePage)
            ? model.activePages[model.visiblePage].sourcePage : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(iOS)
                if horizontalSizeClass == .compact {
                    Button {
                        model.select(nil)
                        didNavigate()
                    } label: {
                        Label("书库", systemImage: "arrow.left")
                    }.buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 12)
                }
            #endif
            HStack {
                Text(tab == "outline" ? "目录" : "文内查找")
                    .font(ReaderTheme.editorial(21)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    if tab == "outline" {
                        tab = "search"
                        searchFocused = true
                    } else {
                        tab = "outline"
                    }
                } label: {
                    Label(
                        tab == "outline" ? "查找正文或译文" : "返回目录",
                        systemImage: tab == "outline" ? "magnifyingglass" : "list.bullet.indent"
                    ).labelStyle(.iconOnly).frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.borderless).foregroundStyle(ReaderTheme.muted)
                .help(tab == "outline" ? "文内查找（⌘F）" : "返回目录")
            }
            .padding(.horizontal, 18).frame(height: 56)
            if tab == "outline" { outline } else { search }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(ReaderTheme.sidebar)
            .task(id: model.selectedPaperID) { await model.loadNavigation() }
            .onChange(of: findRequest) { _, _ in
                tab = "search"
                searchFocused = true
            }
            .onChange(of: model.selectedPaperID) { _, _ in
                query = ""
                tab = "outline"
            }
    }

    private var outline: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.navigationLoading { ProgressView().controlSize(.mini).padding(8) }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(model.navigationItems) { item in
                            Button {
                                model.navigateToSourcePage(item.sourcePage)
                                didNavigate()
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(item.title)
                                        .font(.system(size: 13, weight: item.depth == 0 ? .medium : .regular))
                                        .foregroundStyle(item.depth == 0 ? ReaderTheme.ink : ReaderTheme.muted)
                                        .lineLimit(item.isOutline ? 2 : 3)
                                        .multilineTextAlignment(.leading).padding(
                                            .leading, CGFloat(min(4, item.depth)) * 10)
                                    Spacer(minLength: 0)
                                    Text("\(item.sourcePage + 1)").font(.caption.monospacedDigit())
                                        .foregroundStyle(ReaderTheme.muted)
                                }.padding(.horizontal, 12).padding(.vertical, 10).frame(
                                    maxWidth: .infinity, alignment: .leading
                                )
                                .background(
                                    sourcePage == item.sourcePage ? ReaderTheme.elevated : .clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                ).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(item.id)
                                .accessibilityLabel("\(item.title)，原文第 \(item.sourcePage + 1) 页")
                        }
                    }.padding(10)
                }
                .onChange(of: sourcePage) { _, page in
                    if let item = model.navigationItems.first(where: { $0.sourcePage == page }) {
                        scroll.scrollTo(item.id)
                    }
                }
            }
        }
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
            Text("查找已提取正文与已完成译文").font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                .padding(.horizontal, 22).padding(.top, 12)
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
