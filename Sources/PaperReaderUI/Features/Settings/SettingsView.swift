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
    private let contextHint: String?
    private let openGuide: () -> Void
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
    @State private var confirmLeaveForGuide = false
    @State private var isTesting = false
    @State private var feedback: String?
    @State private var feedbackIsError = false
    @State private var cleanupWarning: String?
    @State private var testTask: Task<Void, Never>?

    init(
        model: ReaderModel, contextHint: String? = nil, openGuide: @escaping () -> Void,
        openMemorySource: @escaping (UUID) -> Void
    ) {
        self.model = model
        self.contextHint = contextHint
        self.openMemorySource = openMemorySource
        self.openGuide = openGuide
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
            .frame(width: 680, height: 510)
        #else
            .presentationSizing(.form)
        #endif
        .confirmationDialog("放弃未保存的设置并打开引导？", isPresented: $confirmLeaveForGuide, titleVisibility: .visible) {
            Button("放弃更改并打开", role: .destructive, action: openGuide)
            Button("继续编辑", role: .cancel) {}
        }
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
            case .success(let url):
                Task {
                    if !(await model.selectVault(url)), let message = model.message {
                        model.message = nil
                        feedback = message
                        feedbackIsError = true
                    }
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { showError(error) }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(ReaderTheme.editorial(24, weight: .medium))
                .padding(.horizontal, 14).padding(.top, 24).padding(.bottom, 18)
            VStack(spacing: 3) {
                ForEach(Category.allCases, id: \.self) { item in
                    let selected = item == category
                    Button {
                        category = item
                    } label: {
                        HStack(spacing: 10) {
                            ReaderActionSymbol(item.symbol)
                                .foregroundStyle(selected ? ReaderTheme.accent : ReaderTheme.muted)
                                .frame(width: 18)
                            Text(item.rawValue)
                            Spacer(minLength: 4)
                            if item == .model && hasModelEdits {
                                Circle().fill(ReaderTheme.accent).frame(width: 6, height: 6)
                                    .accessibilityLabel("有未保存的更改")
                            }
                        }
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? ReaderTheme.ink : ReaderTheme.muted)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 38)
                        .sidebarSelectionTarget(selected)
                        .contentShape(Rectangle())
                    }
                    .readerIconButtonStyle(.plain).disabled(isTesting)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .sidebarSelectionIndicator(
                for: category, in: RoundedRectangle(cornerRadius: 9), reduceMotion: reduceMotion
            )
            .padding(.horizontal, 10)
            Spacer()
            guideButton.padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 158)
        .background(ReaderTheme.sidebar)
    }

    private var guideButton: some View {
        Button {
            if hasModelEdits { confirmLeaveForGuide = true } else { openGuide() }
        } label: {
            Label("快速上手", systemImage: "questionmark.circle").labelStyle(ReaderSymbolLabelStyle())
        }
        .readerIconButtonStyle(.borderless).foregroundStyle(ReaderTheme.muted).disabled(isTesting)
    }

    private var compactNavigation: some View {
        HStack(spacing: 3) {
            ForEach(Category.allCases, id: \.self) { item in
                let selected = category == item
                Button {
                    category = item
                } label: {
                    HStack(spacing: 5) {
                        Text(item.rawValue).font(.callout.weight(selected ? .semibold : .regular))
                        if item == .model && hasModelEdits {
                            Circle().fill(ReaderTheme.accent).frame(width: 5, height: 5)
                                .accessibilityLabel("有未保存的更改")
                        }
                    }
                    .foregroundStyle(selected ? ReaderTheme.accent : ReaderTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .sidebarSelectionTarget(selected).contentShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .sidebarSelectionIndicator(for: category, in: Capsule(), reduceMotion: reduceMotion)
        .padding(3).background(ReaderTheme.sidebar, in: Capsule()).disabled(isTesting)
        .accessibilityElement(children: .contain).accessibilityLabel("设置分类")
        .padding(.horizontal, 20).padding(.top, 18)
    }

    private func detail(compact: Bool) -> some View {
        let index = Category.allCases.firstIndex(of: category) ?? 0
        let destination = compact ? CGPoint(x: CGFloat(index) * 12, y: 0) : CGPoint(x: 0, y: CGFloat(index) * 9)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(category.rawValue)
                        .font(ReaderTheme.editorial(28, weight: .medium))
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
                .padding(.horizontal, compact ? 20 : 28).padding(.top, compact ? 18 : 24).padding(.bottom, 18)
            }
            .modifier(
                WorkspaceArrival(destination: destination, background: ReaderTheme.canvas, usesCompactNavigation: false)
            )
            Divider()
            footer(compact: compact)
        }
    }

    private var modelForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let contextHint, !contextHint.isEmpty {
                Label(contextHint, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(ReaderTheme.ink)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ReaderTheme.elevated, in: RoundedRectangle(cornerRadius: 9))
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("服务预设")
                ReaderPopupMenu(
                    "服务预设",
                    items: ModelServicePreset.allCases.map { preset in
                        .action(preset.displayName, selected: preset == provider) { selectProvider(preset) }
                    }, width: 250
                ) {
                    HStack(spacing: 12) {
                        ReaderActionSymbol("network").foregroundStyle(ReaderTheme.accent)
                            .accessibilityHidden(true)
                        Text(provider.displayName).font(.body.weight(.medium))
                        Spacer(minLength: 6)
                        ReaderActionSymbol("chevron.up.chevron.down").font(.caption2.weight(.semibold))
                            .foregroundStyle(ReaderTheme.muted).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 13).frame(minHeight: 40).contentShape(Rectangle())
                    .background(fieldBackground(focused: false))
                    .accessibilityElement(children: .combine)
                }
                .accessibilityValue(provider.displayName)
            }
            if provider == .custom {
                input("API 地址", field: .address) {
                    TextField("https://example.com/v1", text: Binding(get: { draft.baseURL }, set: { editAddress($0) }))
                        .textContentType(.URL)
                }
            }
            input("模型 ID", field: .model) {
                TextField("模型名称", text: $draft.model)
            }
            credentials
            if provider != .custom, let endpoint = try? draft.endpointURL() {
                DisclosureGroup("请求地址") {
                    Text(endpoint.absoluteString).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption).foregroundStyle(ReaderTheme.muted)
            }
        }
    }

    @ViewBuilder private var credentials: some View {
        VStack(alignment: .leading, spacing: 6) {
            if usesLocalModelKey {
                HStack {
                    fieldLabel("API 密钥")
                    Spacer()
                    Label("已从 .env 载入", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(ReaderTheme.accent)
                }
            } else {
                HStack {
                    fieldLabel("API 密钥")
                    Image(systemName: "lock").font(.caption2).foregroundStyle(ReaderTheme.muted)
                        .help("密钥仅存于本机钥匙串")
                    Spacer()
                    if hasSavedKey && sameEndpoint {
                        Button(removeKey ? "撤销移除" : "移除密钥") {
                            removeKey.toggle()
                            key = ""
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                }
                SecureField(canReuseKey ? "已保存 · 留空沿用" : "输入 API Key", text: $key)
                    .accessibilityLabel("API 密钥").disabled(removeKey)
                    .modifier(SettingsTextField()).focused($focusedField, equals: .key)
                    .background(fieldBackground(focused: focusedField == .key))
                if removeKey {
                    Text("保存后将移除此密钥").font(.caption).foregroundStyle(ReaderTheme.accent)
                }
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

    private static let reviewIntervals: [(label: String, seconds: TimeInterval)] = [
        ("30 分钟", 1_800), ("1 小时", 3_600), ("3 小时", 10_800),
        ("6 小时", 21_600), ("12 小时", 43_200), ("一天", 86_400),
    ]

    private var notesForm: some View {
        @Bindable var noteReview = model.noteReview
        let currentIntervalLabel =
            Self.reviewIntervals.first { abs($0.seconds - noteReview.interval) < 1 }?.label ?? "6 小时"
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Obsidian 目录")
                HStack(spacing: 11) {
                    Image(systemName: "folder").foregroundStyle(ReaderTheme.accent)
                    Text(model.vaultName).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("选择…") { chooseFolder = true }
                }
                .padding(.horizontal, 13).frame(minHeight: 42)
                .background(fieldBackground(focused: false))
                .help("导出笔记时写入此目录")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Toggle("空闲时自动整理笔记", isOn: $noteReview.enabled).font(.callout)
                    Spacer(minLength: 6)
                    if noteReview.running {
                        ProgressView().controlSize(.small)
                        Button("停止") { noteReview.interrupt() }.buttonStyle(.borderless).font(.caption)
                    } else {
                        Button("立即整理") { noteReview.run(reader: model, automatic: false, withModel: true) }
                            .buttonStyle(.borderless).font(.caption)
                            .disabled(model.state.readingNotes.allSatisfy { $0.deletedAt != nil })
                    }
                }
                HStack {
                    Text("整理间隔").font(.callout).foregroundStyle(ReaderTheme.muted)
                    Spacer()
                    ReaderPopupMenu(
                        "整理间隔",
                        items: Self.reviewIntervals.map { option in
                            .action(option.label, selected: abs(option.seconds - noteReview.interval) < 1) {
                                noteReview.interval = option.seconds
                            }
                        }, width: 150
                    ) {
                        ReaderMenuValueLabel(currentIntervalLabel).font(.callout)
                    }
                    .accessibilityValue(currentIntervalLabel)
                }
                if let reviewMessage = noteReview.message {
                    Text(verbatim: reviewMessage).font(.caption).foregroundStyle(ReaderTheme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ReaderTheme.line))
            .help("有新笔记时以修订追加，不覆盖原笔记，计入 API 用量")
            Label("所有数据仅保存在本机", systemImage: "internaldrive")
                .font(.caption).foregroundStyle(ReaderTheme.muted)
        }
    }

    private func footer(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let feedback {
                Label(feedback, systemImage: feedbackIsError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(feedbackIsError ? Color.red : ReaderTheme.accent)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if category != .model && hasModelEdits {
                HStack(spacing: 8) {
                    Label("「模型服务」有未保存更改", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(ReaderTheme.accent)
                    Spacer(minLength: 4)
                    Button("前往查看") { category = .model }
                        .buttonStyle(.borderless).font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(ReaderTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 12) {
                if compact { guideButton.labelStyle(.iconOnly) }
                if category == .model {
                    Button(action: testConnection) {
                        HStack(spacing: 6) {
                            if isTesting { ProgressView().controlSize(.small) }
                            Text(isTesting ? "测试中…" : "测试连接")
                        }
                    }
                    .buttonStyle(.borderless).font(.subheadline.weight(.medium)).disabled(isTesting)
                    .help("发送一次最小连通性请求，会使用少量 API 额度")
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
        .controlSize(.large).padding(.horizontal, compact ? 20 : 28).padding(.vertical, 12)
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
            do {
                let saved = try await model.hasSavedAPIKey()
                hasSavedKey = saved
                model.updateModelCredentialReady(saved)
            } catch { showError(error) }
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
            let hadKeyBeforeSave =
                canReuseKey || usesLocalModelKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let warning = try model.saveSettings(draft, key: key, removeKey: removeKey)
            model.updateModelCredentialReady(hadKeyBeforeSave && !removeKey)
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
