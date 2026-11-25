import PaperReaderKit
import SwiftUI

struct ReflowLoadingView: View {
    let model: ReaderModel

    var body: some View {
        if let paper = model.paper {
            let running = model.isReflowPlaying(paper.id)
            let finished = paper.reflowJob?.finished == true
            let stage = model.reflowStages[paper.id]
            VStack(spacing: 18) {
                ReflowBookAnimation(running: running)
                    .frame(width: 98, height: 76).accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(running ? stage ?? "准备双语版" : (finished ? "未找到可翻译正文" : "双语重排"))
                        .font(ReaderTheme.editorial(22)).foregroundStyle(ReaderTheme.ink)
                    if !running, let failure = model.reflowFailure(for: paper) {
                        Text(failure).font(.callout).foregroundStyle(ReaderTheme.muted)
                    }
                }
                .multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack(spacing: 18) {
                    Button("查看原版", action: model.readOriginal)
                    if running || !finished {
                        ReflowPlaybackButton(running: running) {
                            if running { model.pauseTranslation() } else { model.startAIReflow() }
                        }
                        .disabled(!running && model.translating.contains(paper.id))
                    }
                    if model.reflowBodyCount > 0 {
                        Button("先开始阅读", action: model.presentReflowContent)
                            .foregroundStyle(ReaderTheme.accent)
                    }
                }
                .buttonStyle(.borderless).font(.callout).tint(ReaderTheme.muted)
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReaderTheme.canvas)
        }
    }
}
