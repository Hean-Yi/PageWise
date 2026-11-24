import PaperReaderKit
import SwiftUI

#if os(macOS)
    import AppKit
#endif

private struct SearchInput {
    let query: Binding<String>
    let focus: FocusState<Bool>.Binding
    let step: @MainActor (Int) -> KeyPress.Result
    let submit: @MainActor () -> KeyPress.Result
    let dismiss: @MainActor () -> Void
}

extension EnvironmentValues {
    @Entry fileprivate var librarySearchInput: SearchInput?
}

private struct SearchFieldAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct LibrarySearchField: View {
    @Environment(\.librarySearchInput) private var input
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let input {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(ReaderTheme.muted)
                TextField("搜索书库", text: input.query)
                    .textFieldStyle(.plain).focused(input.focus).submitLabel(.search)
                    .accessibilityLabel("搜索书库").accessibilityIdentifier("library-search-field")
                    .onSubmit { _ = input.submit() }
                    .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape], phases: [.down, .repeat]) { key in
                        guard key.modifiers.intersection([.shift, .option, .command, .control]).isEmpty else {
                            return .ignored
                        }
                        #if os(macOS)
                            if let editor = NSApplication.shared.keyWindow?.firstResponder as? NSTextInputClient,
                                editor.hasMarkedText()
                            {
                                return .ignored
                            }
                        #endif
                        if key.key == .escape {
                            input.dismiss()
                            return .handled
                        }
                        if key.key == .return { return input.submit() }
                        return input.step(key.key == .downArrow ? 1 : -1)
                    }
                if !input.query.wrappedValue.isEmpty {
                    Button {
                        input.query.wrappedValue = ""
                        input.focus.wrappedValue = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                    .help("清除搜索").accessibilityLabel("清除搜索")
                } else {
                    #if os(macOS)
                        Text("⌘ F").font(.system(size: 10)).foregroundStyle(ReaderTheme.muted)
                            .accessibilityHidden(true)
                    #endif
                }
            }
            .font(.callout).padding(.horizontal, 12).frame(minHeight: 36)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(input.focus.wrappedValue ? ReaderTheme.accent : ReaderTheme.line)
                    .animation(ReaderMotion.feedback(reduceMotion), value: input.focus.wrappedValue)
                    .allowsHitTesting(false)
            }
            .anchorPreference(key: SearchFieldAnchor.self, value: .bounds) { $0 }
        }
    }
}

extension View {
    func librarySearchSuggestions(
        state: LibraryState, findRequest: Int, dismissRequest: Int = 0, onSelect: @escaping (UUID) -> Void
    ) -> some View {
        modifier(
            LibrarySearchSuggestions(
                state: state, findRequest: findRequest, dismissRequest: dismissRequest, onSelect: onSelect))
    }
}

private struct LibrarySearchSuggestions: ViewModifier {
    let state: LibraryState
    let findRequest: Int
    let dismissRequest: Int
    let onSelect: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 64
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var selection: UUID?
    @State private var keyboardScrollTarget: UUID?

    func body(content: Content) -> some View {
        let showing = focused && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let matches = showing ? LibraryQuery.searchCandidates(in: state, query: query) : []
        content
            .environment(
                \.librarySearchInput,
                SearchInput(
                    query: Binding(
                        get: { query },
                        set: {
                            guard query != $0 else { return }
                            query = $0
                            selection = nil
                            keyboardScrollTarget = nil
                        }), focus: $focused,
                    step: { delta in
                        guard !matches.isEmpty else { return .ignored }
                        let index = selection.flatMap { id in matches.firstIndex { $0.id == id } } ?? 0
                        let next = matches[min(max(index + delta, 0), matches.count - 1)].id
                        selection = next
                        keyboardScrollTarget = next
                        return .handled
                    },
                    submit: {
                        guard let id = activeID(in: LibraryQuery.searchCandidates(in: state, query: query)) else {
                            return .ignored
                        }
                        choose(id)
                        return .handled
                    }, dismiss: dismiss
                )
            )
            .overlayPreferenceValue(SearchFieldAnchor.self) { anchor in
                if showing, let anchor {
                    GeometryReader { proxy in
                        panel(in: proxy.size, field: proxy[anchor], matches: matches, current: activeID(in: matches))
                    }
                    .transition(.opacity)
                }
            }
            .animation(ReaderMotion.feedback(reduceMotion), value: showing)
            .onChange(of: findRequest) { _, _ in focused = true }
            .onChange(of: dismissRequest) { _, _ in dismiss() }
    }

    @ViewBuilder private func panel(in size: CGSize, field: CGRect, matches: [Paper], current: UUID?) -> some View {
        let bounds = CGRect(origin: .zero, size: size)
        let gap: CGFloat = 6
        let below = size.height - field.maxY - gap
        let above = field.minY - gap
        let placeBelow = below >= rowHeight * 2 || below >= above
        let height = min(max(0, placeBelow ? below : above), min(5.5, CGFloat(max(matches.count, 1))) * rowHeight + 8)
        let width = min(max(0, size.width - 16), max(field.width, 356))
        if field.intersects(bounds), height > 0 {
            let backdrop = Path { path in
                path.addRect(bounds)
                path.addRect(field.intersection(bounds))
            }
            backdrop.fill(.clear, style: FillStyle(eoFill: true))
                .contentShape(backdrop, eoFill: true).onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
            Group {
                if matches.isEmpty {
                    Label("没有匹配的论文", systemImage: "magnifyingglass")
                        .font(.callout).foregroundStyle(ReaderTheme.muted)
                } else {
                    ScrollViewReader { scroll in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(matches) { paper in
                                    row(paper, selected: current == paper.id)
                                        .frame(height: rowHeight).id(paper.id)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .onChange(of: keyboardScrollTarget) { _, id in
                            if let id { scroll.scrollTo(id) }
                        }
                        .onChange(of: query, initial: true) { _, _ in
                            if let first = matches.first { scroll.scrollTo(first.id, anchor: .top) }
                        }
                    }.padding(4)
                }
            }
            .frame(width: width, height: height)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderTheme.line).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .accessibilityElement(children: .contain).accessibilityLabel("书库搜索结果")
            .position(
                x: min(max(field.maxX - width, 8), size.width - width - 8) + width / 2,
                y: placeBelow ? field.maxY + gap + height / 2 : field.minY - gap - height / 2)
        }
    }

    private func row(_ paper: Paper, selected: Bool) -> some View {
        let shelf = state.shelfID(for: paper.id).flatMap { id in state.shelves.first { $0.id == id }?.name } ?? "未分类论文"
        return Button {
            choose(paper.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                SearchMatchText(paper.title, matches: titleMatches(in: paper.title))
                    .font(.callout.weight(.medium)).foregroundStyle(ReaderTheme.ink)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Label {
                    Text(shelf)
                } icon: {
                    ReaderIcon(.library, size: 13)
                }
                .font(.caption).foregroundStyle(ReaderTheme.muted).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(selected ? ReaderTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false)
        .onHover { inside in
            if inside {
                selection = paper.id
                keyboardScrollTarget = nil
            }
        }
        .accessibilityLabel("\(paper.title)，\(shelf)").accessibilityHint("在书架定位")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("library-search-result-\(paper.id)")
    }

    private func titleMatches(in title: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in Set(query.split(whereSeparator: \.isWhitespace)) {
            var remainder = title[...]
            while let range = remainder.localizedStandardRange(of: term), !range.isEmpty {
                ranges.append(range)
                remainder = remainder[range.upperBound...]
            }
        }
        return ranges
    }

    private func choose(_ id: UUID) {
        dismiss()
        onSelect(id)
    }

    private func activeID(in matches: [Paper]) -> UUID? {
        selection.flatMap { id in matches.contains { $0.id == id } ? id : nil } ?? matches.first?.id
    }

    private func dismiss() {
        query = ""
        selection = nil
        keyboardScrollTarget = nil
        focused = false
    }
}
