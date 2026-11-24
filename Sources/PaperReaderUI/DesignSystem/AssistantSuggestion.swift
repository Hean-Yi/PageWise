import SwiftUI

struct AssistantSuggestion: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).readerSymbolInk().frame(width: 18).foregroundStyle(ReaderTheme.accent)
                Text(title).foregroundStyle(ReaderTheme.ink)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.left").readerSymbolInk().font(.caption2).foregroundStyle(ReaderTheme.muted)
            }
            .font(.callout).padding(.horizontal, 10).frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .readerIconButtonStyle(AssistantToolButtonStyle(embedded: true))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
