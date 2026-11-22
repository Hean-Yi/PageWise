import PaperReaderKit
import SwiftUI

enum PDFBilingualLayoutPreference: String {
    case auto, split, stacked, paragraph

    func resolved(at width: CGFloat) -> PDFSentenceTextCanvas.Layout {
        switch self {
        case .auto: width >= 740 ? .split : .stacked
        case .split: width >= 570 ? .split : .stacked
        case .stacked: .stacked
        case .paragraph: .paragraph
        }
    }
}

struct PDFBilingualReadingView: View {
    let model: ReaderModel
    let penEnabled: Bool
    let openSettings: () -> Void

    @Binding var layout: PDFBilingualLayoutPreference
    @Binding var peekingAtOriginal: Bool
    @AppStorage("PDFBilingualFontSize") private var fontSize = 16
    @SceneStorage("PDFBilingualOriginalFraction") private var originalFraction = 0.53
    @State private var dragStart: Double?
    @Environment(\.layoutDirection) private var layoutDirection

    private var session: PDFBilingualSession { model.pdfBilingual }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let textLayout = layout.resolved(at: width)
            let spread = textLayout == .split && session.isOpen && !peekingAtOriginal
            let pdfVisible = !session.isOpen || peekingAtOriginal || spread
            let pdfWidth = spread ? min(width - 268, max(240, width * originalFraction)) : width
            HStack(spacing: 0) {
                PDFCanvas(model: model, penEnabled: pdfVisible && penEnabled, acceptsSentenceInput: pdfVisible)
                    .frame(maxWidth: session.isOpen ? .infinity : 820)
                    .frame(width: pdfWidth)
                    .frame(width: pdfVisible ? pdfWidth : 0)
                    .clipped()
                    .opacity(pdfVisible ? 1 : 0)
                    .allowsHitTesting(pdfVisible)
                    .accessibilityHidden(!pdfVisible)
                if session.isOpen && !peekingAtOriginal {
                    if spread { splitter(width: width).frame(width: 8) }
                    pane(textLayout: textLayout, allowsSplit: width >= 570)
                }
            }
            .overlay(alignment: .topTrailing) {
                if session.isOpen && peekingAtOriginal {
                    Button {
                        peekingAtOriginal = false
                    } label: {
                        Label(layout == .paragraph ? "返回段落重排" : "返回逐句对照", systemImage: "arrow.uturn.backward")
                            .font(.callout.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).tint(ReaderTheme.accent).padding(16)
                }
            }
            .onChange(of: pdfVisible) { _, visible in
                session.hover(nil)
                if visible, let id = session.focusedID { session.focus(id) }
            }
        }
        .onChange(of: session.isOpen) { _, _ in peekingAtOriginal = false }
        .onChange(of: session.selectionRequestRevision) { _, _ in peekingAtOriginal = false }
        .onChange(of: layout) { _, _ in peekingAtOriginal = false }
    }

    private func splitter(width: CGFloat) -> some View {
        Rectangle().fill(ReaderTheme.canvas)
            .overlay(Rectangle().fill(ReaderTheme.line).frame(width: 1))
            .overlay(Capsule().fill(ReaderTheme.muted.opacity(0.45)).frame(width: 3, height: 28))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? originalFraction
                        dragStart = start
                        let offset = value.translation.width * (layoutDirection == .rightToLeft ? -1 : 1)
                        let minFraction = max(0.32, 240 / width)
                        let maxFraction = min(0.68, 1 - 260 / width)
                        originalFraction = min(maxFraction, max(minFraction, start + offset / width))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityLabel("调整原页和译文宽度")
            .accessibilityAdjustableAction { direction in
                originalFraction = min(0.62, max(0.42, originalFraction + (direction == .increment ? 0.03 : -0.03)))
            }
    }

    private func pane(textLayout: PDFSentenceTextCanvas.Layout, allowsSplit: Bool) -> some View {
        let split = textLayout == .split
        let paragraphs = textLayout == .paragraph
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(split ? "简体中文" : (paragraphs ? "英汉段落对照" : "英汉对照")).font(.headline)
                    Text(pageStatus).font(.caption).foregroundStyle(ReaderTheme.muted).monospacedDigit()
                }
                Spacer(minLength: 4)
                if !split && (paragraphs || !session.translations.isEmpty) {
                    Button {
                        peekingAtOriginal = true
                    } label: {
                        Label("查看原页", systemImage: "doc.text.magnifyingglass")
                    }.help("查看原页").accessibilityLabel("查看原页")
                }
                Menu {
                    Picker("对照布局", selection: $layout) {
                        Label("段落重排", systemImage: "text.alignleft").tag(PDFBilingualLayoutPreference.paragraph)
                        Label("逐句上下", systemImage: "rectangle.split.1x2").tag(PDFBilingualLayoutPreference.stacked)
                        Label("左右并排", systemImage: "rectangle.split.2x1")
                            .tag(PDFBilingualLayoutPreference.split).disabled(!allowsSplit)
                        Text("随窗口调整").tag(PDFBilingualLayoutPreference.auto)
                    }
                    Divider()
                    Menu("译文字号") {
                        Picker("译文字号", selection: $fontSize) {
                            Text("小").tag(14)
                            Text("标准").tag(16)
                            Text("大").tag(19)
                        }
                    }
                    if split {
                        Toggle(
                            "跟随原句", isOn: Binding(get: { session.followsScroll }, set: { session.followsScroll = $0 }))
                    }
                } label: {
                    Image(
                        systemName: paragraphs
                            ? "text.alignleft" : (split ? "rectangle.split.2x1" : "rectangle.split.1x2"))
                }.fixedSize().help("对照布局与译文字号").accessibilityLabel("对照布局")
            }
            .buttonStyle(.borderless).padding(.horizontal, 22).padding(.vertical, 14)
            Divider()
            if let notice = session.notice {
                Text(notice).font(.caption).foregroundStyle(ReaderTheme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.top, 8)
            }
            if let error = session.error {
                HStack(alignment: .firstTextBaseline) {
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("模型设置", action: openSettings).fixedSize()
                }
                .padding(12).background(ReaderTheme.accent.opacity(0.07))
            }
            if let source = session.selectionSource {
                selectionResult(source)
            }
            if session.translations.isEmpty && (!paragraphs || session.sentences.isEmpty) {
                emptyPage
            } else {
                PDFSentenceTextCanvas(
                    sentences: session.sentences, translations: session.translations,
                    layout: textLayout, fontSize: fontSize, activeID: session.activeID, focusedID: session.focusedID,
                    focusRevision: session.sourceFocusRevision, followsScroll: session.followsScroll,
                    sourceScrollID: session.sourceScrollID, sourceScrollRevision: session.sourceScrollRevision,
                    pdfSelectedIDs: session.pdfSelectedIDs, onScroll: session.scrollFromTranslation,
                    onSelection: session.selectFromTranslation, onFocus: session.focus, onHover: session.hover)
                if session.selectionSource == nil
                    && (session.isTranslating || session.translations.count < session.sentences.count)
                {
                    Divider()
                    HStack(spacing: 12) {
                        translationActions
                        if !session.isTranslating { serviceDisclosure }
                    }.padding(.horizontal, 20).padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ReaderTheme.surface)
    }

    private var pageStatus: String {
        let page = "原页 \(model.visiblePage + 1)"
        guard !session.sentences.isEmpty else { return page }
        let completed = session.translations.count
        if completed == 0 { return "\(page) · \(session.sentences.count) 句" }
        if completed == session.sentences.count { return "\(page) · 已译 \(completed) 句" }
        return "\(page) · 已译 \(completed) / \(session.sentences.count) 句"
    }

    private var emptyPage: some View {
        VStack(spacing: 14) {
            if session.isLoading {
                ProgressView().controlSize(.small)
                Text("正在读取本页文字").font(.callout).foregroundStyle(ReaderTheme.muted)
            } else if session.sentences.isEmpty {
                Image(systemName: "doc.text.viewfinder").font(.title2).foregroundStyle(ReaderTheme.muted)
                Text(layout == .paragraph ? "本页暂无可重排的文字" : "本页暂无可逐句对照的文字").font(.headline)
                if layout != .paragraph {
                    Button("查看原页") { peekingAtOriginal = true }.buttonStyle(.bordered)
                }
            } else {
                Image(systemName: "text.bubble").font(.system(size: 26, weight: .light)).foregroundStyle(
                    ReaderTheme.accent)
                translationActions
                if !session.isTranslating { serviceDisclosure.multilineTextAlignment(.center) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var serviceDisclosure: some View {
        let name = model.pdfTranslationSettings.model
        return Text(name.isEmpty ? "配置模型后可翻译本页英文" : "本页英文将发送至 \(name)")
            .font(.caption).foregroundStyle(ReaderTheme.muted).textSelection(.enabled)
    }

    @ViewBuilder private var translationActions: some View {
        if session.isTranslating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在翻译").font(.callout)
                Button("暂停") { session.pause() }.buttonStyle(.borderless).padding(.leading, 5)
            }
        } else {
            Button {
                if model.pdfTranslationSettings.model.isEmpty {
                    openSettings()
                } else {
                    model.pdfBilingual.translatePage(model)
                }
            } label: {
                Label(session.translations.isEmpty ? "翻译本页" : "继续翻译本页", systemImage: "character.bubble")
                    .padding(.horizontal, 5).padding(.vertical, 3)
            }.buttonStyle(.borderedProminent).tint(ReaderTheme.accent).disabled(session.isLoading)
        }
    }

    private func selectionResult(_ source: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("选区译文").font(.caption.weight(.semibold)).foregroundStyle(ReaderTheme.accent)
                if session.isTranslating && session.selectionTranslation == nil {
                    ProgressView().controlSize(.small)
                    Text("正在翻译选区").font(.caption).foregroundStyle(ReaderTheme.muted)
                }
                Spacer()
                Button {
                    session.dismissSelection()
                } label: {
                    Image(systemName: "xmark").padding(4)
                }
                .buttonStyle(.plain).foregroundStyle(ReaderTheme.muted)
                .accessibilityLabel("关闭选区译文").help("关闭选区译文")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text(source).font(.callout.italic()).foregroundStyle(ReaderTheme.muted).textSelection(.enabled)
                    if let result = session.selectionTranslation {
                        Text(result).font(.body).lineSpacing(4).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
            if session.selectionContextID != nil {
                Button("对照整句") { session.showSelectionContext() }
                    .buttonStyle(.borderless).font(.caption.weight(.medium))
                    .help("查看这一句已保存的英文和译文")
            }
        }.padding(16).background(ReaderTheme.accent.opacity(0.045))
    }
}
