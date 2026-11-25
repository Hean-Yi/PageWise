import PaperReaderKit
import SwiftUI

struct ReflowLoadingView: View {
    let model: ReaderModel

    var body: some View {
        if let paper = model.paper {
            let running = model.isReflowPlaying(paper.id)
            let finished = paper.reflowJob?.finished == true
            let stage = model.reflowStages[paper.id]
            VStack(spacing: 20) {
                ReflowBookAnimation(running: running)
                    .aspectRatio(4.0 / 3, contentMode: .fit).frame(maxWidth: 224).accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(running ? stage ?? "准备双语版" : (finished ? "未找到可翻译正文" : "双语重排"))
                        .font(ReaderTheme.editorial(22)).foregroundStyle(ReaderTheme.ink)
                    if !running, let failure = model.reflowFailure(for: paper) {
                        Text(failure).font(.callout).foregroundStyle(ReaderTheme.muted)
                    }
                }
                .multilineTextAlignment(.center).frame(maxWidth: 420)
                VStack(spacing: 6) {
                    if running || !finished {
                        ReflowPlaybackButton(running: running, prominent: true) {
                            if running { model.pauseTranslation() } else { model.startAIReflow() }
                        }
                        .disabled(!running && model.translating.contains(paper.id))
                    }
                    if model.reflowBodyCount > 0 {
                        Button(action: model.presentReflowContent) {
                            Label("先开始阅读", readerIcon: .openNote, size: 14).foregroundStyle(ReaderTheme.accent)
                                .padding(.horizontal, 8).readerIconTarget(macOS: 36)
                        }
                        .readerPlainButton().help("阅读已就绪的双语段落")
                    } else if finished && !running && paper.translations.isEmpty {
                        Button(action: model.readOriginal) {
                            Label("阅读原版", readerIcon: .paper, size: 14).foregroundStyle(ReaderTheme.muted)
                                .padding(.horizontal, 8).readerIconTarget(macOS: 36)
                        }
                        .readerPlainButton().help("阅读原版 PDF")
                    }
                }.font(.callout)
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReaderTheme.canvas)
        }
    }
}
