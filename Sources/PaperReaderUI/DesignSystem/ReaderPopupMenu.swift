import SwiftUI

/// App commands share a printed treatment across toolbar buttons, context clicks and touch.
enum ReaderMenuItem {
    case action(
        _ title: String, icon: ReaderIcon.Glyph? = nil, selected: Bool = false, enabled: Bool = true,
        destructive: Bool = false, run: @MainActor () -> Void)
    case submenu(_ title: String, items: [ReaderMenuItem])
    case section(String)
    case divider

    var selectable: Bool {
        switch self {
        case .action(_, _, _, let enabled, _, _): enabled
        case .submenu(_, let children): !children.isEmpty
        default: false
        }
    }

    var selected: Bool {
        if case .action(_, _, let selected, _, _, _) = self { return selected }
        return false
    }
}

struct ReaderMenuValueLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            ReaderIcon(.chevron, size: 10).rotationEffect(.degrees(90))
        }
    }
}

struct ReaderPopupMenu<Label: View>: View {
    let title: String
    let items: () -> [ReaderMenuItem]
    let width: CGFloat
    @ViewBuilder let label: () -> Label
    @State private var open = false

    init(
        _ title: String, items: @autoclosure @escaping () -> [ReaderMenuItem], width: CGFloat = 208,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.title = title
        self.items = items
        self.width = width
        self.label = label
    }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            label().contentShape(Rectangle())
        }
        .readerIconButtonStyle(.plain)
        .accessibilityLabel(Text(title))
        .readerMenuPresentation(open: $open, title: title, items: items, width: width)
    }
}

extension View {
    @ViewBuilder func readerMenuPresentation(
        open: Binding<Bool>, title: String, items: @escaping () -> [ReaderMenuItem], width: CGFloat,
        point: CGPoint? = nil
    ) -> some View {
        #if os(macOS)
            background { ReaderMenuAnchor(open: open, title: title, items: items, width: width, point: point) }
        #else
            popover(
                isPresented: open,
                attachmentAnchor: .rect(
                    point.map { .rect(CGRect(origin: $0, size: CGSize(width: 1, height: 1))) } ?? .bounds)
            ) {
                ReaderMenuPanel(title: title, items: items(), width: width) { open.wrappedValue = false }
            }
        #endif
    }

    func readerPopupSurface() -> some View {
        foregroundStyle(ReaderTheme.ink)
            .background(ReaderTheme.surface)
            .presentationBackground(ReaderTheme.surface)
            .presentationCompactAdaptation(.popover)
    }
}

struct ReaderMenuPanel: View {
    let title: String
    let items: [ReaderMenuItem]
    let width: CGFloat
    let dismiss: () -> Void
    @State private var path: [Int] = []
    @State private var hovered: Int?
    @FocusState private var focus: Int?
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var page: (title: String, items: [ReaderMenuItem]) {
        var result = (title, items)
        for index in path {
            guard result.1.indices.contains(index),
                case .submenu(let name, let children) = result.1[index]
            else { break }
            result = (name, children)
        }
        return result
    }

    var body: some View {
        let page = page
        VStack(alignment: .leading, spacing: 0) {
            if !path.isEmpty {
                Button {
                    back()
                } label: {
                    HStack(spacing: 7) {
                        ReaderIcon(.chevron, size: 12).rotationEffect(.degrees(180))
                        Text(page.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 9).frame(minHeight: rowHeight)
                }
                .readerIconButtonStyle(.plain).foregroundStyle(ReaderTheme.accent)
                .accessibilityLabel("返回上一级，" + page.title)
                rule
            }
            ViewThatFits(in: .vertical) {
                rows(page.items).fixedSize(horizontal: false, vertical: true)
                ScrollView { rows(page.items) }.frame(height: 360)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(width: width)
        .readerPopupSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(page.title))
        .onAppear { focus = initialFocus(page.items) }
        .onKeyPress(keys: [.downArrow, .upArrow, .leftArrow, .rightArrow, .return, .space, .escape]) { key in
            switch key.key {
            case .escape: dismiss()
            case .return, .space:
                guard let focus, page.items.indices.contains(focus) else { return .ignored }
                activate(page.items[focus], index: focus)
            case .leftArrow:
                guard !path.isEmpty else { return .ignored }
                back()
            case .rightArrow:
                guard let focus, page.items.indices.contains(focus), case .submenu = page.items[focus]
                else { return .ignored }
                activate(page.items[focus], index: focus)
            default:
                let indices = page.items.indices.filter { page.items[$0].selectable }
                guard !indices.isEmpty else { return .ignored }
                let position = focus.flatMap { indices.firstIndex(of: $0) }
                let next = key.key == .downArrow ? (position ?? -1) + 1 : (position ?? indices.count) - 1
                hovered = nil
                focus = indices[(next + indices.count) % indices.count]
            }
            return .handled
        }
    }

    private func rows(_ entries: [ReaderMenuItem]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(entries.indices, id: \.self) { index in
                switch entries[index] {
                case .divider: rule
                case .section(let name):
                    Text(name).font(.caption.weight(.semibold)).foregroundStyle(ReaderTheme.muted)
                        .padding(.horizontal, 9).padding(.top, 6).padding(.bottom, 3)
                        .accessibilityAddTraits(.isHeader)
                case .action(let name, let icon, _, _, let destructive, _):
                    row(name, icon: icon, index: index, entry: entries[index], destructive: destructive)
                case .submenu(let name, _):
                    row(name, index: index, entry: entries[index], disclosure: true)
                }
            }
        }
    }

    private var rule: some View {
        Rectangle().fill(ReaderTheme.line).frame(height: 1)
            .padding(.horizontal, 8).padding(.vertical, 4).accessibilityHidden(true)
    }

    private func row(
        _ name: String, icon: ReaderIcon.Glyph? = nil, index: Int, entry: ReaderMenuItem,
        destructive: Bool = false, disclosure: Bool = false
    ) -> some View {
        let active = (hovered ?? focus) == index
        return Button(role: destructive ? .destructive : nil) {
            activate(entry, index: index)
        } label: {
            HStack(spacing: 8) {
                if let icon { ReaderIcon(icon, size: 15).frame(width: 18) }
                Text(name).font(.callout.weight(entry.selected ? .semibold : .regular))
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 5)
                if entry.selected {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(ReaderTheme.accent)
                        .accessibilityHidden(true)
                } else if disclosure {
                    ReaderIcon(.chevron, size: 12).foregroundStyle(ReaderTheme.muted)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 3)
            .frame(minHeight: rowHeight)
            .foregroundStyle(destructive || entry.selected ? ReaderTheme.accent : ReaderTheme.ink)
            .background(
                active && entry.selectable ? ReaderTheme.elevated : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .readerIconButtonStyle(.plain)
        .disabled(!entry.selectable).opacity(entry.selectable ? 1 : 0.45)
        .focused($focus, equals: index).focusEffectDisabled()
        .onHover { inside in
            if inside && entry.selectable { hovered = index }
            if !inside && hovered == index { hovered = nil }
        }
        .accessibilityAddTraits(entry.selected ? .isSelected : [])
    }

    private func activate(_ entry: ReaderMenuItem, index: Int) {
        guard entry.selectable else { return }
        switch entry {
        case .action(_, _, _, _, _, let run):
            dismiss()
            run()
        case .submenu(_, let children):
            withAnimation(ReaderMotion.feedback(reduceMotion)) { path.append(index) }
            hovered = nil
            focus = initialFocus(children)
        default: break
        }
    }

    private func back() {
        guard let parentRow = path.popLast() else { return }
        hovered = nil
        focus = parentRow
    }

    private func initialFocus(_ entries: [ReaderMenuItem]) -> Int? {
        entries.indices.first { entries[$0].selectable && entries[$0].selected }
            ?? entries.indices.first { entries[$0].selectable }
    }
}
