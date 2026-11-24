import SwiftUI

struct PDFBilingualAppearanceMenu: View {
    @Binding var layout: PDFBilingualLayoutPreference
    let width: CGFloat
    @AppStorage("PDFBilingualFontSize") private var fontSize = 16

    var body: some View {
        ReaderPopupMenu("阅读外观", items: items) {
            Image(systemName: "textformat.size").readerSymbolInk().readerIconTarget(macOS: 30)
        }.fixedSize().help("阅读外观")
    }

    private var items: [ReaderMenuItem] {
        let layouts: [(String, PDFBilingualLayoutPreference)] = [
            ("段落对照", .paragraph), ("原页与译文并排", .split),
        ]
        var items: [ReaderMenuItem] = [.section("对照布局")]
        items += layouts.map { title, value in
            .action(title, selected: layout == value, enabled: value != .split || width >= 570) {
                layout = value
            }
        }
        items += [.divider, .section("译文字号")]
        items += [("小", 14), ("标准", 16), ("大", 19)].map { title, value in
            .action(title, selected: fontSize == value) { fontSize = value }
        }
        return items
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
                        Label(label, systemImage: symbol(status)).labelStyle(ReaderSymbolLabelStyle()).fixedSize()
                        Image(systemName: symbol(status)).readerSymbolInk()
                    }
                }
                .readerIconButtonStyle(.borderless).accessibilityLabel(label).help(label)
                .popover(isPresented: $showingDetails) {
                    details(status, paperID: paperID)
                        .readerPopupSurface()
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
                .font(ReaderTheme.editorial(16, weight: .semibold)).monospacedDigit()
            if progress.partialPages > 0 { Text("\(progress.partialPages) 页有缺译") }
            if progress.skippedPages > 0 { Text("\(progress.skippedPages) 页保留原版") }
            switch status.phase {
            case .running:
                if let page = progress.activePageIndex {
                    Text("正在处理第 \(page + 1) 页").foregroundStyle(ReaderTheme.muted)
                }
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
        .font(.callout).foregroundStyle(ReaderTheme.ink).tint(ReaderTheme.accent)
        .buttonStyle(.borderless).padding(16).frame(idealWidth: 240, maxWidth: 320, alignment: .leading)
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
                Label("暂停本页翻译", systemImage: "pause.circle").labelStyle(ReaderSymbolLabelStyle())
            }.readerIconButtonStyle(.borderless)
        } else {
            Button {
                if model.modelSettings.model.isEmpty { openSettings() } else { session.translatePage(model) }
            } label: {
                Label(session.translations.isEmpty ? "翻译本页" : "继续翻译本页", systemImage: "character.bubble").labelStyle(
                    ReaderSymbolLabelStyle())
            }
            .readerIconButtonStyle(.borderless).disabled(session.isLoading)
        }
    }
}
