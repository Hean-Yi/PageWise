import SwiftUI

struct ReflowPlaybackButton: View {
    let running: Bool
    let action: () -> Void

    var body: some View {
        let title: LocalizedStringKey = running ? "暂停生成" : "继续生成"
        Button(action: action) {
            ReaderIcon(running ? .pause : .play, size: 17)
                .foregroundStyle(ReaderTheme.ink)
                .readerIconTarget(macOS: 30)
                .readerGlassSurface(in: Circle(), fallback: ReaderTheme.elevated)
        }
        .readerPlainButton(cornerRadius: ReaderTheme.iconTarget(30) / 2)
        .accessibilityLabel(title)
        .help(title)
    }
}
