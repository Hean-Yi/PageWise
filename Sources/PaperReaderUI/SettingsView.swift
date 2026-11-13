import PaperReaderKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModelSettings
    @State private var savedSettings: ModelSettings
    @State private var provider: String
    @State private var tab = "model"
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var removeKey = false
    @State private var chooseFolder = false
    @State private var isTesting = false
    @State private var feedback: String?
    @State private var feedbackIsError = false
    @State private var cleanupWarning: String?
    @State private var testTask: Task<Void, Never>?

    init(model: ReaderModel) {
        self.model = model
        _draft = State(initialValue: model.modelSettings)
        _savedSettings = State(initialValue: model.modelSettings)
        let isGLM = (try? model.modelSettings.endpointURL()) == (try? ModelSettings().endpointURL())
        _provider = State(initialValue: isGLM ? "glm" : "custom")
    }

    private var sameEndpoint: Bool {
        guard let endpoint = try? draft.endpointURL() else { return false }
        return endpoint == (try? savedSettings.endpointURL())
    }
    private var canReuseKey: Bool { hasSavedKey && sameEndpoint && !removeKey }
    private var keyStatus: String {
        if removeKey { return "保存后移除" }
        if !key.isEmpty { return "新密钥待保存" }
        return canReuseKey ? "已保存于此设备" : "尚未配置"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2).foregroundStyle(ReaderTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(ReaderTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置").font(.title2.bold())
                }
                Spacer()
            }.padding(24)
            Picker("设置分类", selection: $tab) {
                Text("模型服务").tag("model")
                Text("笔记与存储").tag("notes")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if tab == "model" { modelForm } else { notesForm }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .background(ReaderTheme.canvas)
        .tint(ReaderTheme.accent)
        #if os(macOS)
            .frame(width: 600, height: 700)
        #else
            .presentationSizing(.form)
        #endif
        .onAppear { refreshKeyStatus() }
        .onChange(of: draft) { _, _ in feedback = nil }
        .onChange(of: draft.baseURL) { _, _ in
            provider = (try? draft.endpointURL()) == (try? ModelSettings().endpointURL()) ? "glm" : "custom"
        }
        .onChange(of: key) { _, _ in feedback = nil }
        .onChange(of: removeKey) { _, _ in feedback = nil }
        .onDisappear {
            testTask?.cancel()
            key = ""
        }
        .alert("设置已保存", isPresented: Binding(get: { cleanupWarning != nil }, set: { if !$0 { cleanupWarning = nil } }))
        {
            Button("知道了") { dismiss() }
        } message: {
            Text(cleanupWarning ?? "")
        }
        .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await model.selectVault(url) }
            case .failure(let error): showError(error)
            }
        }
    }

    @ViewBuilder private var modelForm: some View {
        card {
            Picker(
                "服务预设",
                selection: Binding(
                    get: { provider },
                    set: { value in
                        provider = value
                        draft.baseURL = value == "glm" ? ModelSettings.glmBaseURL : ""
                        key = ""
                        removeKey = false
                    })
            ) {
                Text("智谱 GLM").tag("glm")
                Text("自定义兼容接口").tag("custom")
            }
            Divider()
            field("API 地址", detail: "HTTPS 基础地址或完整接口地址") {
                TextField("https://example.com/v1", text: $draft.baseURL)
                    .accessibilityLabel("API 地址").textContentType(.URL)
            }
            field("模型名称", detail: "服务商提供的模型 ID") {
                TextField("输入模型 ID", text: $draft.model).accessibilityLabel("模型名称")
            }
            if let endpoint = try? draft.endpointURL() {
                DisclosureGroup("请求地址") {
                    Text(endpoint.absoluteString).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.disabled(isTesting)
        card {
            HStack {
                Label("API Key", systemImage: "key.horizontal").font(.headline)
                Spacer()
                Text(keyStatus).font(.caption).foregroundStyle(canReuseKey ? ReaderTheme.accent : ReaderTheme.muted)
            }
            SecureField(canReuseKey ? "留空保留已保存的密钥" : "填写此服务的 API Key", text: $key)
                .accessibilityLabel("API Key").textFieldStyle(.roundedBorder)
                .disabled(removeKey)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
            HStack(alignment: .top, spacing: 12) {
                Text("仅存于本机 Keychain")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if hasSavedKey && sameEndpoint {
                    Button(removeKey ? "撤销移除" : "移除密钥") {
                        removeKey.toggle()
                        key = ""
                    }.buttonStyle(.borderless).foregroundStyle(removeKey ? ReaderTheme.accent : Color.red)
                }
            }
            if !sameEndpoint && hasSavedKey {
                Text("新地址需要重新填写密钥")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(isTesting)
        Label("Chat Completions", systemImage: "network")
            .font(.caption).foregroundStyle(.secondary)
            .help("翻译与问答使用此接口，相关文字及检索片段将发送给该服务。")
    }

    @ViewBuilder private var notesForm: some View {
        card {
            Label("Obsidian 笔记", systemImage: "doc.text").font(.headline)
            LabeledContent("已授权目录", value: model.vaultName)
            Button("选择笔记目录…") { chooseFolder = true }
            Text("选定目录即生效。笔记仅在你点击保存时写入。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        card {
            Label("本地优先", systemImage: "internaldrive").font(.headline)
            Text("论文、阅读记录与批注保存在此设备。")
            Text("iCloud 自动同步尚未启用。每台设备分别配置 API Key。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let feedback {
                Label(feedback, systemImage: feedbackIsError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.subheadline).foregroundStyle(feedbackIsError ? Color.red : ReaderTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tab == "model" {
                Text("测试会使用 API 额度")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("仅发送一条测试消息，不包含论文与笔记，不会保存草稿。")
            }
            HStack(spacing: 12) {
                if tab == "model" {
                    Button(action: testConnection) {
                        HStack(spacing: 6) {
                            if isTesting { ProgressView().controlSize(.small) }
                            Text(isTesting ? "测试中…" : "测试连接")
                        }
                    }.disabled(isTesting)
                }
                Spacer(minLength: 0)
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存设置", action: save).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(isTesting)
            }
        }.padding(20)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.15)))
    }

    private func field<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View
    {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.medium))
            content().textFieldStyle(.roundedBorder).autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshKeyStatus() {
        do { hasSavedKey = try model.hasSavedAPIKey() } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        feedbackIsError = true
        feedback = error.localizedDescription
    }

    private func save() {
        if draft == savedSettings && key.isEmpty && !removeKey {
            dismiss()
            return
        }
        do {
            let warning = try model.saveSettings(draft, key: key, removeKey: removeKey)
            key = ""
            removeKey = false
            draft = model.modelSettings
            savedSettings = model.modelSettings
            if let warning {
                refreshKeyStatus()
                cleanupWarning = warning
            } else {
                dismiss()
            }
        } catch { showError(error) }
    }

    private func testConnection() {
        feedback = nil
        isTesting = true
        let snapshot = draft
        let testKey = key
        let shouldRemove = removeKey
        testTask = Task { @MainActor in
            defer { isTesting = false }
            do {
                try await model.testModelConnection(snapshot, key: testKey, removeKey: shouldRemove)
                feedbackIsError = false
                feedback = "连接成功 · 保存后生效"
            } catch is CancellationError {
                // Closing the settings cancels the test without surfacing an error.
            } catch { if !Task.isCancelled { showError(error) } }
        }
    }
}
