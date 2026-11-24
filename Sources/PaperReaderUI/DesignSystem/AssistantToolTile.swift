import SwiftUI

/// Shared label for a tool result or a citation. The caller supplies the actual action.
struct AssistantToolTile: View {
    let tool: String
    let systemImage: String
    let title: String
    var detail: String?
    var metadata: String?
    var accessory: String?
    var accessoryRotation: Angle = .zero
    var detailLines = 2
    var searchQuery: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: systemImage).accessibilityHidden(true)
                Text(tool).fontWeight(.semibold)
                Spacer(minLength: 2)
                if let metadata, !metadata.isEmpty {
                    Text(metadata).monospacedDigit().foregroundStyle(ReaderTheme.muted)
                }
                if let accessory {
                    Image(systemName: accessory).font(.caption2.weight(.semibold))
                        .rotationEffect(accessoryRotation)
                        .foregroundStyle(ReaderTheme.muted).accessibilityHidden(true)
                }
            }.font(.caption).foregroundStyle(ReaderTheme.accent)
            SearchMatchText(title, query: searchQuery).font(.callout.weight(.medium)).foregroundStyle(ReaderTheme.ink)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                SearchMatchText(detail, query: searchQuery).font(.caption).foregroundStyle(ReaderTheme.muted)
                    .lineLimit(detailLines).fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func assistantToolSurface(highlighted: Bool = false, pressed: Bool = false) -> some View {
        modifier(AssistantToolSurface(highlighted: highlighted, pressed: pressed))
    }
}

private struct AssistantToolSurface: ViewModifier {
    let highlighted: Bool
    let pressed: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let stroke = contrast == .increased ? ReaderTheme.muted : ReaderTheme.line
        return
            content
            .background(pressed || highlighted ? ReaderTheme.elevated : ReaderTheme.surface, in: shape)
            .overlay {
                shape.strokeBorder(highlighted || pressed ? ReaderTheme.accent : stroke)
                    .allowsHitTesting(false)
            }
    }
}

struct AssistantToolButtonStyle: ButtonStyle {
    var embedded = false

    func makeBody(configuration: Configuration) -> some View {
        LabelBody(configuration: configuration, embedded: embedded)
    }

    private struct LabelBody: View {
        let configuration: ButtonStyleConfiguration
        let embedded: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let active = hovered && enabled
            Group {
                if embedded {
                    configuration.label.background(active || configuration.isPressed ? ReaderTheme.elevated : .clear)
                } else {
                    configuration.label.assistantToolSurface(highlighted: active, pressed: configuration.isPressed)
                }
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(ReaderMotion.feedback(reduceMotion), value: active)
            .animation(ReaderMotion.feedback(reduceMotion), value: configuration.isPressed)
            .onHover { hovered = $0 }
        }
    }
}
