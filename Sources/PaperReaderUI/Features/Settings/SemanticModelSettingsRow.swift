import SwiftUI

struct SemanticModelSettingsRow: View {
    let model: ReaderModel
    private let settings = SemanticModelSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地中英语义检索").font(.subheadline.weight(.semibold))
                    Text(
                        settings.isBundled
                            ? "已随应用内置（离线运行，无需额外下载）"
                            : (settings.installed ? "多语言模型已安装" : "多语言模型 · 约 240 MB")
                    )
                    .font(.caption).foregroundStyle(ReaderTheme.muted)
                }
                Spacer()
                if settings.isBundled {
                    Label("就绪", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(ReaderTheme.accent)
                } else if settings.working {
                    ProgressView().controlSize(.small)
                    Button("取消") { Task { await settings.cancel() } }
                } else {
                    Button(settings.installed ? "移除模型" : "下载模型") {
                        Task { await settings.changeInstallation(in: model) }
                    }
                }
            }
            if let error = settings.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await settings.refresh() }
    }
}
