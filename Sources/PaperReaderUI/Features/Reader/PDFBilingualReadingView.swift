import PaperReaderKit
import SwiftUI

struct PDFBilingualReadingView: View {
    let model: ReaderModel
    let penEnabled: Bool
    let openSettings: () -> Void

    @AppStorage("PDFBilingualDisplayLayout") private var layout = "auto"
    @AppStorage("PDFBilingualFontSize") private var fontSize = 16
    @SceneStorage("PDFBilingualOriginalFraction") private var originalFraction = 0.53
    @State private var dragStart: Double?
    @State private var peekingAtOriginal = false
    @Environment(\.layoutDirection) private var layoutDirection

    private var session: PDFBilingualSession { model.pdfBilingual }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let split = layout == "split" ? width >= 570 : (layout == "auto" && width >= 740)
            let spread = split && session.isOpen && !peekingAtOriginal
            let pdfVisible = !session.isOpen || peekingAtOriginal || spread
            let pdfWidth = spread ? min(width - 268, max(240, width * originalFraction)) : width
            HStack(spacing: 0) {
                PDFCanvas(model: model, penEnabled: penEnabled, acceptsSentenceInput: pdfVisible)
                    .frame(maxWidth: session.isOpen ? .infinity : 820)
                    .frame(width: pdfWidth)
                    .frame(width: pdfVisible ? pdfWidth : 0)
                    .clipped()
                    .opacity(pdfVisible ? 1 : 0)
                    .allowsHitTesting(pdfVisible)
                    .accessibilityHidden(!pdfVisible)
                if session.isOpen && !peekingAtOriginal {
                    if spread { splitter(width: width).frame(width: 8) }
                    pane(split: spread, allowsSplit: width >= 570)
                }
            }
            .overlay(alignment: .topTrailing) {
                if session.isOpen && peekingAtOriginal {
                    Button {
                        peekingAtOriginal = false
                    } label: {
                        Label("返回逐句对照", systemImage: "arrow.uturn.backward")
                            .font(.callout.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).tint(ReaderTheme.accent).padding(16)
                }
            }
        }
        .onChange(of: session.isOpen) { _, _ in peekingAtOriginal = false }
        .onChange(of: session.selectionRequestRevision) { _, _ in peekingAtOriginal = false }
        .onChange(of: peekingAtOriginal) { _, visible in
            if visible, let id = session.focusedID { session.focus(id) }
        }
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

    private func pane(split: Bool, allowsSplit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(split ? "简体中文" : "英汉对照").font(.headline)
                    Text(pageStatus).font(.caption).foregroundStyle(ReaderTheme.muted).monospacedDigit()
                }
                Spacer(minLength: 4)
                if !split && !session.translations.isEmpty {
                    Button {
                        peekingAtOriginal = true
                    } label: {
                        Label("查看原页", systemImage: "doc.text.magnifyingglass")
                    }.help("查看原页").accessibilityLabel("查看原页")
                }
                Menu {
                    Picker("对照布局", selection: $layout) {
                        Text("随窗口调整").tag("auto")
                        Label("左右并排", systemImage: "rectangle.split.2x1").tag("split").disabled(!allowsSplit)
                        Label("逐句上下", systemImage: "rectangle.split.1x2").tag("stacked")
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
                    Image(systemName: split ? "rectangle.split.2x1" : "rectangle.split.1x2")
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
            if session.translations.isEmpty {
                emptyPage
            } else {
                PDFSentenceTextCanvas(
                    sentences: session.sentences, translations: session.translations,
                    stacked: !split, fontSize: fontSize, activeID: session.activeID, focusedID: session.focusedID,
                    focusRevision: session.sourceFocusRevision, followsScroll: session.followsScroll,
                    sourceScrollID: session.sourceScrollID, sourceScrollRevision: session.sourceScrollRevision,
                    pdfSelectedIDs: session.pdfSelectedIDs, onScroll: session.scrollFromTranslation,
                    onSelection: session.selectFromTranslation, onFocus: session.focus, onHover: session.hover)
                if session.selectionSource == nil
                    && (session.isTranslating || session.translations.count < session.sentences.count)
                {
                    Divider()
                    translationActions.padding(.horizontal, 20).padding(.vertical, 10)
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
                Text("本页暂无可逐句对照的文字").font(.headline)
                Button("查看原页") { peekingAtOriginal = true }.buttonStyle(.bordered)
            } else {
                Image(systemName: "text.bubble").font(.system(size: 26, weight: .light)).foregroundStyle(
                    ReaderTheme.accent)
                translationActions
                if !session.isTranslating && !session.serviceName.isEmpty {
                    Text("本页英文将发送至 \(session.serviceName)")
                        .font(.caption).foregroundStyle(ReaderTheme.muted)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
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
                model.pdfBilingual.translatePage(model)
            } label: {
                Label(session.translations.isEmpty ? "翻译本页" : "继续翻译本页", systemImage: "character.bubble")
                    .padding(.horizontal, 5).padding(.vertical, 3)
            }.buttonStyle(.borderedProminent).tint(ReaderTheme.accent)
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
