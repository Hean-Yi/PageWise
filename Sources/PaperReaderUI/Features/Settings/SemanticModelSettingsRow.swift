import SwiftUI

struct SemanticModelSettingsRow: View {
    let model: ReaderModel
    private let settings = SemanticModelSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地语义检索").font(.headline)
                    Text(settings.installed ? "多语言模型已安装" : "多语言模型 · 约 240 MB")
                        .font(.caption).foregroundStyle(ReaderTheme.muted)
                }
                Spacer()
                if settings.working {
                    ProgressView().controlSize(.small)
                    Button("取消") { Task { await settings.cancel() } }
                } else {
                    Button(settings.installed ? "移除模型" : "下载模型") {
                        Task { await settings.changeInstallation(in: model) }
                    }
                }
            }
            if let error = settings.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .task { await settings.refresh() }
    }
}
