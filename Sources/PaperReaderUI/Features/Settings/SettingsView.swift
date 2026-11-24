import PaperReaderKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum Category: String, CaseIterable {
        case model = "模型服务"
        case notes = "笔记与存储"
        case memory = "研究记忆"

        var symbol: String {
            switch self {
            case .model: "slider.horizontal.3"
            case .notes: "folder"
            case .memory: "brain.head.profile"
            }
        }
    }

    private enum Field { case model, address, key }

    @Bindable var model: ReaderModel
    private let openMemorySource: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?
    @State private var draft: ModelSettings
    @State private var savedSettings: ModelSettings
    @State private var provider: ModelServicePreset
    @State private var category: Category = .model
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var removeKey = false
    @State private var chooseFolder = false
    @State private var isTesting = false
    @State private var feedback: String?
    @State private var feedbackIsError = false
    @State private var cleanupWarning: String?
    @State private var testTask: Task<Void, Never>?

    init(model: ReaderModel, openMemorySource: @escaping (UUID) -> Void) {
        self.model = model
        self.openMemorySource = openMemorySource
        let settings = model.modelSettings
        _draft = State(initialValue: Self.initialDraft(settings))
        _savedSettings = State(initialValue: settings)
        _provider = State(initialValue: ModelServicePreset.matching(settings))
    }

    private static func initialDraft(_ settings: ModelSettings) -> ModelSettings {
        var draft = settings
        if draft.model.isEmpty { draft.model = ModelServicePreset.matching(settings).defaultModel }
        return draft
    }

    private var hasModelEdits: Bool {
        draft != Self.initialDraft(savedSettings) || !key.isEmpty || removeKey
    }

    private var sameEndpoint: Bool {
        guard let endpoint = try? draft.endpointURL() else { return false }
        return endpoint == (try? savedSettings.endpointURL())
    }

    private var usesLocalModelKey: Bool { model.usesLocalModelKey(for: draft) }
    private var canReuseKey: Bool { hasSavedKey && sameEndpoint && !removeKey }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 610 {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    detail(compact: false)
                }
            } else {
                VStack(spacing: 0) {
                    compactNavigation
                    detail(compact: true)
                }
            }
        }
        .background(ReaderTheme.canvas)
        .foregroundStyle(ReaderTheme.ink)
        .tint(ReaderTheme.accent)
        #if os(macOS)
            .frame(width: 720, height: 570)
        #else
            .presentationSizing(.form)
        #endif
        .onAppear { refreshKeyStatus() }
        .onChange(of: draft) { _, _ in feedback = nil }
        .onChange(of: usesLocalModelKey) { _, usesLocal in
            if usesLocal {
                key = ""
                removeKey = false
            }
        }
        .onChange(of: key) { _, _ in feedback = nil }
        .onChange(of: removeKey) { _, _ in feedback = nil }
        .onChange(of: category) { _, _ in
            focusedField = nil
            feedback = nil
        }
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
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { showError(error) }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设置")
                .font(ReaderTheme.editorial(25, weight: .medium))
                .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 22)
            ForEach(Category.allCases, id: \.self) { item in
                Button {
                    category = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.rawValue)
                    }
                    .font(.subheadline.weight(item == category ? .semibold : .regular))
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 37)
                    .foregroundStyle(item == category ? ReaderTheme.ink : ReaderTheme.muted)
                    .background(item == category ? ReaderTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .animation(ReaderMotion.feedback(reduceMotion), value: item == category)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(isTesting)
                .accessibilityAddTraits(item == category ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12).frame(width: 155)
        .background(ReaderTheme.sidebar)
    }

    private var compactNavigation: some View {
        Picker("设置分类", selection: $category) {
            ForEach(Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().disabled(isTesting)
        .padding(.horizontal, 20).padding(.top, 18)
    }

    private func detail(compact: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) {
                        Text(category.rawValue)
                            .font(ReaderTheme.editorial(32, weight: .medium))
                            .accessibilityAddTraits(.isHeader)
                        switch category {
                        case .model: modelForm.disabled(isTesting)
                        case .notes: notesForm
                        case .memory:
                            MemoryView(model: model) { paperID in
                                openMemorySource(paperID)
                                if hasModelEdits {
                                    feedback = "已在阅读窗口打开来源论文"
                                    feedbackIsError = false
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, compact ? 22 : 32).padding(.top, compact ? 20 : 27).padding(.bottom, 20)
                }
                .id(category)
                .transition(ReaderMotion.arrival(y: 5))
            }
            .animation(ReaderMotion.disclosure(reduceMotion), value: category)
            Divider()
            footer(compact: compact)
        }
    }

    private var modelForm: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("服务预设")
                Menu {
                    Picker("服务预设", selection: Binding(get: { provider }, set: { selectProvider($0) })) {
                        ForEach(ModelServicePreset.allCases) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "network").foregroundStyle(ReaderTheme.accent)
                            .accessibilityHidden(true)
                        Text(provider.displayName).font(.body.weight(.medium))
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                            .foregroundStyle(ReaderTheme.muted).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 13).frame(minHeight: 42).contentShape(Rectangle())
                    .background(fieldBackground(focused: false))
                    .accessibilityElement(children: .combine)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel("服务预设").accessibilityValue(provider.displayName)
            }
            if provider == .custom {
                input("API 地址", field: .address) {
                    TextField("https://example.com/v1", text: Binding(get: { draft.baseURL }, set: { editAddress($0) }))
                        .textContentType(.URL)
                }
            }
            input("模型 ID", field: .model) {
                TextField("输入账户可用的模型 ID", text: $draft.model)
            }
            credentials
            if provider != .custom, let endpoint = try? draft.endpointURL() {
                DisclosureGroup("请求地址") {
                    Text(endpoint.absoluteString).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                }
                .font(.callout).foregroundStyle(ReaderTheme.muted)
            }
        }
    }

    @ViewBuilder private var credentials: some View {
        VStack(alignment: .leading, spacing: 7) {
            if usesLocalModelKey {
                fieldLabel("API 密钥")
                Label("本机 .env", systemImage: "checkmark.circle")
                    .accessibilityLabel("密钥已从本机 .env 载入")
                    .font(.callout).foregroundStyle(ReaderTheme.muted).padding(.vertical, 6)
            } else {
                HStack {
                    fieldLabel("API 密钥")
                    Spacer()
                    if hasSavedKey && sameEndpoint {
                        Button(removeKey ? "撤销移除" : "移除密钥") {
                            removeKey.toggle()
                            key = ""
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                }
                SecureField(canReuseKey ? "已保存 · 留空沿用" : "输入此服务的 API Key", text: $key)
                    .accessibilityLabel("API 密钥").disabled(removeKey)
                    .modifier(SettingsTextField()).focused($focusedField, equals: .key)
                    .background(fieldBackground(focused: focusedField == .key))
                Label(removeKey ? "保存设置后移除此密钥" : "密钥仅存于本机钥匙串", systemImage: "lock")
                    .font(.caption).foregroundStyle(ReaderTheme.muted)
            }
        }
    }

    private func input(_ label: String, field: Field, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel(label)
            content().accessibilityLabel(label).modifier(SettingsTextField()).focused($focusedField, equals: field)
                .background(fieldBackground(focused: focusedField == field))
        }
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label).font(.subheadline.weight(.semibold))
    }

    private func fieldBackground(focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return shape.fill(ReaderTheme.surface)
            .overlay(shape.strokeBorder(focused ? ReaderTheme.accent : ReaderTheme.line, lineWidth: focused ? 1.5 : 1))
    }

    private var notesForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldLabel("Obsidian 笔记目录")
            HStack(spacing: 11) {
                Image(systemName: "folder").foregroundStyle(ReaderTheme.accent)
                Text(model.vaultName).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 8)
                Button("选择目录…") { chooseFolder = true }
            }
            .padding(13).background(fieldBackground(focused: false))
            Text("选定目录即生效。在笔记侧栏点击「将笔记导出到 Obsidian」时才写入。")
                .font(.callout).foregroundStyle(ReaderTheme.muted)
            Divider().padding(.vertical, 5)
            fieldLabel("设备存储")
            Text("论文、阅读记录与批注保存在这台设备上。")
                .font(.callout).foregroundStyle(ReaderTheme.muted)
        }
    }

    private func footer(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let feedback {
                Label(feedback, systemImage: feedbackIsError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.callout).foregroundStyle(feedbackIsError ? Color.red : ReaderTheme.accent)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                if category == .model {
                    VStack(alignment: .leading, spacing: 3) {
                        Button(action: testConnection) {
                            HStack(spacing: 6) {
                                if isTesting { ProgressView().controlSize(.small) }
                                Text(isTesting ? "正在测试…" : "测试连接")
                            }
                        }
                        .buttonStyle(.borderless).font(.subheadline.weight(.medium)).disabled(isTesting)
                        Text("测试会使用 API 额度").font(.caption2).foregroundStyle(ReaderTheme.muted)
                    }
                }
                Spacer(minLength: 0)
                if category != .model && !hasModelEdits {
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("取消") { dismiss() }.buttonStyle(.borderless).foregroundStyle(ReaderTheme.muted)
                        .keyboardShortcut(.cancelAction)
                    Button("保存设置", action: save).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(isTesting)
                }
            }
        }
        .controlSize(.large).padding(.horizontal, compact ? 20 : 32).padding(.vertical, 13)
    }

    private func selectProvider(_ value: ModelServicePreset) {
        guard provider != value else { return }
        provider = value
        if ModelServicePreset.matching(savedSettings) == value {
            draft.baseURL = savedSettings.baseURL
            draft.model = savedSettings.model.isEmpty ? value.defaultModel : savedSettings.model
        } else {
            draft.baseURL = value.baseURL
            draft.model = value.defaultModel
        }
        key = ""
        removeKey = false
        focusedField = value == .custom ? .address : nil
        feedback = nil
    }

    private func editAddress(_ value: String) {
        let before = try? draft.endpointURL()
        draft.baseURL = value
        if before == nil || before != (try? draft.endpointURL()) {
            key = ""
            removeKey = false
        }
    }

    private func refreshKeyStatus() {
        if model.usesLocalModelKey(for: savedSettings) {
            hasSavedKey = false
            return
        }
        Task {
            do { hasSavedKey = try await model.hasSavedAPIKey() } catch { showError(error) }
        }
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
                feedback = snapshot == savedSettings && testKey.isEmpty ? "连接成功" : "连接成功，保存后生效"
            } catch is CancellationError {
                // Dismissing the sheet cancels its connection test.
            } catch { if !Task.isCancelled { showError(error) } }
        }
    }
}

private struct SettingsTextField: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.body).autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never).frame(minHeight: 44)
            #else
                .frame(minHeight: 38)
            #endif
            .padding(.horizontal, 12)
    }
}
