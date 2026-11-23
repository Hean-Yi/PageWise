import SwiftUI

struct PDFBilingualMenuItems: View {
    let model: ReaderModel
    @Binding var layout: PDFBilingualLayoutPreference
    @Binding var peekingAtOriginal: Bool
    let width: CGFloat
    @AppStorage("PDFBilingualFontSize") private var fontSize = 16

    var body: some View {
        if layout.resolved(at: width) != .split || peekingAtOriginal {
            Button {
                peekingAtOriginal.toggle()
            } label: {
                Label(
                    peekingAtOriginal ? "返回双语重排" : "查看原页",
                    systemImage: peekingAtOriginal ? "arrow.uturn.backward" : "doc.text.magnifyingglass")
            }
        }
        Menu("对照布局") {
            Picker("对照布局", selection: $layout) {
                Text("段落对照").tag(PDFBilingualLayoutPreference.paragraph)
                Text("逐句上下").tag(PDFBilingualLayoutPreference.stacked)
                Text("左右并排").tag(PDFBilingualLayoutPreference.split).disabled(width < 570)
                Text("随窗口调整").tag(PDFBilingualLayoutPreference.auto)
            }.pickerStyle(.inline).labelsHidden()
            if layout.resolved(at: width) == .split {
                Toggle(
                    "跟随原句",
                    isOn: Binding(
                        get: { model.pdfBilingual.followsScroll }, set: { model.pdfBilingual.followsScroll = $0 }))
            }
        }
        Menu("译文字号") {
            Picker("译文字号", selection: $fontSize) {
                Text("小").tag(14)
                Text("标准").tag(16)
                Text("大").tag(19)
            }.pickerStyle(.inline).labelsHidden()
        }
    }
}

struct PDFTranslationStatusControl: View {
    let model: ReaderModel
    let layout: PDFBilingualLayoutPreference
    let openSettings: () -> Void
    @State private var showingDetails = false

    private var session: PDFBilingualSession { model.pdfBilingual }

    var body: some View {
        if let paperID = model.selectedPaperID {
            let status = model.pdfDocumentTranslation.status(for: paperID)
            if layout != .paragraph, session.selectionSource == nil, !session.translations.isEmpty,
                session.sentences.contains(where: { session.translations[$0.id] == nil }),
                status == nil || status?.phase == .completed
            {
                PDFPageTranslationAction(model: model, openSettings: openSettings)
            }
            if let status {
                let label = statusLabel(status)
                Button {
                    if status.phase == .needsConfiguration {
                        openSettings()
                    } else {
                        showingDetails = true
                    }
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label(label, systemImage: symbol(status)).fixedSize()
                        Image(systemName: symbol(status))
                    }
                }
                .buttonStyle(.borderless).accessibilityLabel(label).help(label)
                .popover(isPresented: $showingDetails) {
                    details(status, paperID: paperID)
                        .presentationCompactAdaptation(.popover)
                }
            } else if layout == .paragraph && session.selectionSource == nil {
                Button("翻译全文") { session.setParagraphLayout(true, model: model) }
            }
        }
    }

    private func symbol(_ status: PDFDocumentTranslationStatus) -> String {
        switch status.phase {
        case .running: "character.bubble"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.circle"
        case .needsConfiguration: "slider.horizontal.3"
        case .completed: status.progress.partialPages > 0 ? "text.badge.minus" : "checkmark.circle"
        }
    }

    private func statusLabel(_ status: PDFDocumentTranslationStatus) -> String {
        let progress = status.progress
        switch status.phase {
        case .needsConfiguration: return "设置翻译"
        case .running: return "翻译中 \(progress.processedPages)/\(progress.pageCount)"
        case .paused: return "翻译已暂停"
        case .failed: return "翻译中断"
        case .completed:
            if progress.partialPages > 0 { return "\(progress.partialPages) 页有缺译" }
            if progress.skippedPages > 0 { return "\(progress.skippedPages) 页保留原版" }
            return "全文已译"
        }
    }

    private func details(_ status: PDFDocumentTranslationStatus, paperID: UUID) -> some View {
        let progress = status.progress
        return VStack(alignment: .leading, spacing: 10) {
            Text("已处理 \(progress.processedPages) / \(progress.pageCount) 页")
                .font(.headline).monospacedDigit()
            if progress.partialPages > 0 { Text("\(progress.partialPages) 页有缺译") }
            if progress.skippedPages > 0 { Text("\(progress.skippedPages) 页保留原版") }
            switch status.phase {
            case .running:
                if let page = progress.activePageIndex { Text("正在处理第 \(page + 1) 页").foregroundStyle(.secondary) }
                Button("暂停翻译") {
                    model.pdfDocumentTranslation.pause(paperID)
                    showingDetails = false
                }
            case .paused:
                Button("继续翻译", action: resume)
            case .failed(let reason):
                Text(reason).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !model.modelSettings.model.isEmpty { Button("重试", action: resume) }
                Button("模型设置", action: settings)
            case .needsConfiguration:
                Button("设置翻译", action: settings)
            case .completed:
                if progress.partialPages > 0 { Button("重试缺译部分", action: resume) }
            }
        }
        .font(.callout).padding(16).frame(idealWidth: 240, maxWidth: 320, alignment: .leading)
    }

    private func resume() {
        showingDetails = false
        session.resumeDocumentTranslation(model)
    }

    private func settings() {
        showingDetails = false
        openSettings()
    }
}

struct PDFPageTranslationAction: View {
    let model: ReaderModel
    let openSettings: () -> Void

    var body: some View {
        let session = model.pdfBilingual
        if session.isTranslating {
            Button {
                session.pause()
            } label: {
                Label("暂停本页翻译", systemImage: "pause.circle")
            }
        } else {
            Button {
                if model.modelSettings.model.isEmpty { openSettings() } else { session.translatePage(model) }
            } label: {
                Label(session.translations.isEmpty ? "翻译本页" : "继续翻译本页", systemImage: "character.bubble")
            }
            .disabled(session.isLoading)
        }
    }
}
