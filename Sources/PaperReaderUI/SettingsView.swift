import PaperReaderKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var chooseFolder = false
    var body: some View {
        NavigationStack {
            Form {
                Section("大模型服务") {
                    TextField("HTTPS Base URL", text: $model.modelSettings.baseURL)
                        .autocorrectionDisabled()
                    TextField("模型名称", text: $model.modelSettings.model).autocorrectionDisabled()
                    SecureField("API Key（留空保留现有密钥）", text: $key)
                    Text("翻译、问答、讨论整理共用此服务。填写你账户实际可用的模型名称；GLM 或兼容 Chat Completions 的 HTTPS 接口均可。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("密钥仅保存在此设备 Keychain，不写入笔记或同步数据。所选文本及检索片段将发送给你配置的服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Obsidian") {
                    LabeledContent("已授权目录", value: model.vaultName)
                    Button("选择笔记目录…") { chooseFolder = true }
                    Text("建议选择专用于研究的子目录。该目录中的 Markdown 可作为问答辅助资料；只有点击保存笔记才会写入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("本地 MVP") {
                    Text("资料保存在此设备。iCloud 自动同步尚未启用。")
                    Text("macOS 15+ / iPadOS 18+。复杂图表、公式和扫描件可能回退为普通 PDF；当前问答只处理可提取文字。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("删除此设备的 API Key", role: .destructive) { model.saveSettings(key: "") }
                }
            }.formStyle(.grouped)
                .navigationTitle("模型与笔记设置")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            model.saveSettings(key: key.isEmpty ? nil : key)
                            key = ""
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            key = ""
                            dismiss()
                        }
                    }
                }
                .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
                    switch result {
                    case .success(let url): Task { await model.selectVault(url) }
                    case .failure(let error): model.message = error.localizedDescription
                    }
                }
        }.frame(minWidth: 420, idealWidth: 560, minHeight: 520, idealHeight: 620)
    }
}
