import PaperReaderKit
import SwiftUI

struct ReflowLoadingView: View {
    let model: ReaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let id = model.selectedPaperID ?? UUID()
            let running = model.translating.contains(id)
            let elapsed = context.date.timeIntervalSince(model.reflowStartedAt[id] ?? context.date)
            VStack(spacing: 26) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(ReaderTheme.accent.opacity(0.08)).frame(
                        width: 88, height: 108)
                    Image(systemName: running ? "text.book.closed" : "pause.circle")
                        .font(.system(size: 35, weight: .light)).foregroundStyle(ReaderTheme.accent)
                }
                VStack(spacing: 10) {
                    Text(running ? "正在准备双语阅读" : "重排已暂停")
                        .font(.system(size: 25, weight: .medium, design: .serif))
                    Text(model.paper?.title ?? "").font(.callout).foregroundStyle(ReaderTheme.muted)
                        .multilineTextAlignment(.center).lineLimit(3).frame(maxWidth: 440)
                }
                VStack(spacing: 13) {
                    if running { ProgressView().controlSize(.small) }
                    Text(model.reflowStages[id] ?? model.paper?.reflowJob?.failure ?? "准备论文")
                        .font(.callout).foregroundStyle(ReaderTheme.muted).multilineTextAlignment(.center).frame(
                            maxWidth: 420)
                    if let count = model.paper?.blocks.count, count > 0 {
                        Text("已准备 \(count) 个内容块").font(.caption).foregroundStyle(ReaderTheme.muted)
                    }
                }
                HStack(spacing: 14) {
                    Button("查看原版", action: model.readOriginal).buttonStyle(.bordered)
                    if running {
                        Button("暂停", action: model.pauseTranslation).buttonStyle(.bordered)
                    } else {
                        Button("继续重排") { model.startAIReflow() }.buttonStyle(.borderedProminent)
                    }
                }.controlSize(.large)
                if model.reflowBodyCount > 0 && (!running || elapsed >= 20) {
                    Button("先开始阅读", action: model.presentReflowContent).buttonStyle(.plain)
                        .font(.callout).foregroundStyle(ReaderTheme.accent)
                }
                Text("首批内容就绪后进入正文，其余内容会继续生成")
                    .font(.caption).foregroundStyle(ReaderTheme.muted)
            }
            .padding(36).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReaderTheme.canvas)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: running)
        }
    }
}

struct ReadingModeChoiceView: View {
    let model: ReaderModel
    let reflow: () -> Void
    var body: some View {
        VStack(spacing: 25) {
            Image(systemName: "book.pages").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(
                ReaderTheme.accent)
            Text("开始阅读").font(.system(size: 26, weight: .medium, design: .serif))
            Text(model.paper?.title ?? "").font(.callout).foregroundStyle(ReaderTheme.muted)
                .multilineTextAlignment(.center).lineLimit(3).frame(maxWidth: 440)
            HStack(spacing: 18) {
                Button(action: model.readOriginal) {
                    Label("阅读原版", systemImage: "doc.richtext").padding(.horizontal, 12).padding(.vertical, 8)
                }.buttonStyle(.bordered)
                Button(action: reflow) {
                    Label("AI 双语重排", systemImage: "character.book.closed").padding(.horizontal, 12).padding(
                        .vertical, 8)
                }.buttonStyle(.borderedProminent)
            }.controlSize(.large)
            Text("选择双语重排后才会调用已配置的模型")
                .font(.caption).foregroundStyle(ReaderTheme.muted)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReaderTheme.canvas)
    }
}
