import SwiftUI

struct ReflowPlaybackButton: View {
    let running: Bool
    var prominent = false
    let action: () -> Void

    var body: some View {
        let title: LocalizedStringKey = running ? "暂停生成" : "继续生成"
        let diameter: CGFloat = prominent ? 48 : 30
        Button(action: action) {
            ReaderIcon(running ? .pause : .play, size: prominent ? 24 : 17)
                .foregroundStyle(ReaderTheme.ink)
                .readerIconTarget(macOS: diameter)
                .readerGlassSurface(in: Circle(), fallback: ReaderTheme.elevated, bordered: prominent)
        }
        .readerPlainButton(cornerRadius: ReaderTheme.iconTarget(diameter) / 2)
        .accessibilityLabel(title)
        .help(title)
    }
}
