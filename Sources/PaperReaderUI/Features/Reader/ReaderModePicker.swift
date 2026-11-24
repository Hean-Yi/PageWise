import SwiftUI

struct ReaderModePicker: View {
    @Binding var bilingual: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var focusedMode: Bool?
    @ScaledMetric(relativeTo: .callout) private var segmentWidth: CGFloat = 74

    var body: some View {
        HStack(spacing: 0) {
            segment("原版", bilingualMode: false)
            segment("双语重排", bilingualMode: true)
        }
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: bilingual ? segmentWidth : 0)
                Capsule().fill(ReaderTheme.accent).frame(width: segmentWidth)
            }
            .allowsHitTesting(false)
        }
        .padding(3)
        .background { track }
        .fixedSize()
        .animation(ReaderMotion.navigation(reduceMotion), value: bilingual)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("阅读模式")
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.modifiers.isEmpty, focusedMode != nil else { return .ignored }
            let next = (press.key == .rightArrow) == (layoutDirection == .leftToRight)
            focusedMode = next
            if bilingual != next { bilingual = next }
            return .handled
        }
    }

    private func segment(_ title: LocalizedStringKey, bilingualMode: Bool) -> some View {
        let selected = bilingualMode == bilingual
        return Button {
            if !selected { bilingual = bilingualMode }
        } label: {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(selected ? ReaderTheme.surface : ReaderTheme.muted)
                .lineLimit(1)
                .frame(width: segmentWidth)
                #if os(macOS)
                    .frame(minHeight: 30)
                #else
                    .frame(minHeight: 44)
                #endif
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focusedMode, equals: bilingualMode)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var track: some View {
        if #available(macOS 26, iOS 26, *), !reduceTransparency {
            Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
        } else {
            Capsule().fill(ReaderTheme.elevated)
                .overlay { Capsule().strokeBorder(ReaderTheme.line, lineWidth: 1) }
        }
    }
}
