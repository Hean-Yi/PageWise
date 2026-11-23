import SwiftUI

struct AssistantSuggestion: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 18).foregroundStyle(ReaderTheme.accent)
                Text(title).foregroundStyle(ReaderTheme.ink)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.left").font(.caption2).foregroundStyle(ReaderTheme.muted)
            }
            .font(.callout).padding(.horizontal, 10).frame(minHeight: 42)
            .background(hovered ? ReaderTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}
