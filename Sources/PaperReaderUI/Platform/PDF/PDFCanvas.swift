import PDFKit
import PaperReaderKit
import SwiftUI

#if os(iOS)
    import PencilKit
#endif

struct PDFCanvas: View {
    let model: ReaderModel
    var penEnabled: Bool
    var acceptsSentenceInput = true
    var body: some View {
        let session = model.pdfBilingual
        let focus = PDFSentenceDisplay(
            sentences: session.matches(model) && acceptsSentenceInput ? session.sentences : [],
            activeID: session.activeID,
            focusedID: session.focusedID, revealRevision: session.revealRevision,
            selectedIDs: session.translationSelectedIDs, scrollID: session.pdfScrollID,
            scrollRevision: session.pdfScrollRevision,
            illustration: acceptsSentenceInput && session.matches(model) ? session.sourceIllustration : nil)
        PlatformPDF(model: model, penEnabled: penEnabled, focus: focus)
    }
}

private struct PDFSentenceDisplay {
    let sentences: [PDFSourceSentence]
    let activeID: String?
    let focusedID: String?
    let revealRevision: Int
    let selectedIDs: [String]
    let scrollID: String?
    let scrollRevision: Int
    let illustration: PDFReadingIllustration?
}

@MainActor
private final class ReaderPDFView: PDFView {
    var copyTextProvider: (() -> String?)?

    #if os(macOS)
        var sentencePointer: ((CGPoint, Bool) -> Void)?
        var sentencePointerExited: (() -> Void)?
        var observesSentenceInput = false
        private var eventMonitor: Any?
        private var pointerWasInside = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            guard window != nil else { return }
            // PDFKit's inner document view handles mouse tracking itself. Observe this window's
            // events without consuming them so text selection, links and scrolling keep working.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .mouseMoved]) {
                [weak self] event in
                guard let self, self.observesSentenceInput, let window = self.window,
                    event.window === window, window.attachedSheet == nil
                else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                let inside = self.visibleRect.contains(point)
                if inside {
                    if event.type == .mouseMoved || event.clickCount == 1 {
                        self.sentencePointer?(point, event.type == .leftMouseDown)
                    }
                } else if self.pointerWasInside {
                    self.sentencePointerExited?()
                }
                self.pointerWasInside = inside
                return event
            }
        }
    #endif

    override func copy(_ sender: Any?) {
        guard currentSelection != nil else { return }
        guard let text = copyTextProvider?(), !text.isEmpty else { return }
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}

#if os(macOS)
    private struct PlatformPDF: NSViewRepresentable {
        let model: ReaderModel
        let penEnabled: Bool
        let focus: PDFSentenceDisplay
        func makeCoordinator() -> PDFCoordinator { PDFCoordinator(model: model) }
        func makeNSView(context: Context) -> PDFView { context.coordinator.makeView() }
        func updateNSView(_ view: PDFView, context: Context) {
            context.coordinator.update(view, penEnabled: false, focus: focus)
        }
    }
#else
    private struct PlatformPDF: UIViewRepresentable {
        let model: ReaderModel
        let penEnabled: Bool
        let focus: PDFSentenceDisplay
        func makeCoordinator() -> PDFCoordinator { PDFCoordinator(model: model) }
        func makeUIView(context: Context) -> PDFView { context.coordinator.makeView() }
        func updateUIView(_ view: PDFView, context: Context) {
            context.coordinator.update(view, penEnabled: penEnabled, focus: focus)
        }
    }
#endif

@MainActor
private final class PDFCoordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    let model: ReaderModel
    weak var view: PDFView?
    var displayedDocument: PDFDisplayDocument?
    var identity = ""
    var keys: [String] = []
    var highlightIDs: Set<UUID> = []
    var penEnabled = false
    private var displayedSentenceIDs: [String] = []
    private var scrollRevision = 0
    private var revealRevision: Int?
    private var revealedIllustrationID: String?
    var isUpdating = false
    var paperID: UUID?
    #if os(iOS)
        let toolPicker = PKToolPicker()
        var canvases: [String: PKCanvasView] = [:]
    #endif

    init(model: ReaderModel) { self.model = model }
    func makeView() -> PDFView {
        let view = ReaderPDFView()
        view.copyTextProvider = { [weak self] in self?.selectedSourceText() }
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = false
        view.pageOverlayViewProvider = self
        #if os(macOS)
            view.acceptsDraggedFiles = false
            view.backgroundColor = NSColor(ReaderTheme.canvas)
        #else
            view.backgroundColor = UIColor.secondarySystemBackground
        #endif
        self.view = view
        #if os(macOS)
            view.sentencePointer = { [weak self] point, clicked in
                guard let self else { return }
                let hit = self.sentence(at: point)
                if clicked, let hit {
                    self.model.pdfBilingual.focusFromPDF(hit.id)
                } else {
                    self.model.pdfBilingual.hover(hit?.id)
                }
            }
            view.sentencePointerExited = { [weak self] in self?.model.pdfBilingual.hover(nil) }
        #else
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedPDF(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
        #endif
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        return view
    }

    func update(_ view: PDFView, penEnabled: Bool, focus: PDFSentenceDisplay) {
        isUpdating = true
        defer { isUpdating = false }
        self.penEnabled = penEnabled
        #if os(macOS)
            (view as? ReaderPDFView)?.observesSentenceInput = !focus.sentences.isEmpty
        #endif
        view.isInMarkupMode = penEnabled
        // SwiftUI may update the old representable once after the reader is dismissed.
        guard model.paper != nil, !model.usesHTMLReading else {
            view.document = nil
            displayedDocument = nil
            identity = ""
            keys = []
            paperID = nil
            highlightIDs = []
            #if os(iOS)
                for canvas in canvases.values {
                    toolPicker.setVisible(false, forFirstResponder: canvas)
                    toolPicker.removeObserver(canvas)
                }
                canvases = [:]
            #endif
            return
        }
        let newIdentity = model.pageURLs.map(\.path).joined(separator: "|")
        if identity != newIdentity {
            let oldPage = model.visiblePage
            displayedSentenceIDs = []
            revealRevision = nil
            revealedIllustrationID = nil
            identity = newIdentity
            keys = model.pageKeys
            paperID = model.selectedPaperID
            #if os(iOS)
                for canvas in canvases.values { toolPicker.removeObserver(canvas) }
                canvases = [:]
            #endif
            let document: PDFDocument
            do {
                let loaded = try PDFDisplayDocument.load(urls: model.pageURLs, expectedPageCount: keys.count)
                displayedDocument = loaded
                document = loaded.document
            } catch {
                view.document = nil
                displayedDocument = nil
                highlightIDs = []
                let message = error.localizedDescription
                Task { @MainActor [weak model] in
                    guard let model, !model.usesHTMLReading,
                        model.pageURLs.map(\.path).joined(separator: "|") == newIdentity
                    else { return }
                    model.message = message
                }
                return
            }
            view.document = document
            #if os(macOS)
                NotificationCenter.default.removeObserver(
                    self, name: NSScrollView.didLiveScrollNotification, object: nil)
                if let scroll = view.documentView?.enclosingScrollView {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(originalScrolled), name: NSScrollView.didLiveScrollNotification,
                        object: scroll)
                }
            #else
                if let scroll = view.documentView?.superview as? UIScrollView {
                    scroll.panGestureRecognizer.removeTarget(self, action: #selector(originalScrolled))
                    scroll.panGestureRecognizer.addTarget(self, action: #selector(originalScrolled))
                }
            #endif
            highlightIDs = []
            if let page = document.page(at: min(oldPage, max(0, document.pageCount - 1))) { view.go(to: page) }
        }
        for mark in model.currentHighlights where !highlightIDs.contains(mark.id) {
            guard let index = keys.firstIndex(of: mark.pageKey), let page = view.document?.page(at: index) else {
                continue
            }
            for rect in mark.rects where rect.count == 4 {
                let annotation = PDFAnnotation(
                    bounds: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), forType: .highlight,
                    withProperties: nil)
                #if os(macOS)
                    annotation.color = NSColor.systemYellow.withAlphaComponent(0.45)
                #else
                    annotation.color = UIColor.systemYellow.withAlphaComponent(0.45)
                #endif
                page.addAnnotation(annotation)
            }
            highlightIDs.insert(mark.id)
        }
        if let index = model.jumpPage, let page = view.document?.page(at: index) {
            view.clearSelection()
            view.go(to: page)
            Task { @MainActor [weak self] in
                guard let self, self.identity == newIdentity, self.model.jumpPage == index,
                    self.paperID == self.model.selectedPaperID, self.keys == self.model.pageKeys
                else { return }
                self.model.recordVisiblePage(index)
                self.model.jumpPage = nil
            }
        }
        updateSentenceFocus(in: view, display: focus)
        #if os(iOS)
            for canvas in canvases.values { canvas.isUserInteractionEnabled = penEnabled }
            if let current = view.currentPage, let document = view.document {
                let n = document.index(for: current)
                if keys.indices.contains(n), let canvas = canvases[keys[n]] {
                    toolPicker.setVisible(penEnabled, forFirstResponder: canvas)
                    if penEnabled { canvas.becomeFirstResponder() } else { canvas.resignFirstResponder() }
                }
            }
        #endif
    }

    private func sentence(at point: CGPoint) -> PDFSourceSentence? {
        guard let view, !penEnabled, model.pdfBilingual.matches(model),
            let page = view.page(for: point, nearest: false),
            view.document?.index(for: page) == model.pdfBilingual.pageIndex
        else { return nil }
        let location = view.convert(point, to: page)
        return model.pdfBilingual.sentences.first { sentence in
            sentence.rects.contains { Self.rectangle($0)?.insetBy(dx: -0.5, dy: -0.5).contains(location) == true }
        }
    }

    #if os(iOS)
        @objc private func tappedPDF(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended, let view, let hit = sentence(at: gesture.location(in: view)) {
                model.pdfBilingual.focusFromPDF(hit.id)
            }
        }
    #endif

    private static func rectangle(_ values: [Double]) -> CGRect? {
        guard values.count == 4, values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private func updateSentenceFocus(in view: PDFView, display: PDFSentenceDisplay) {
        let ids = display.selectedIDs.isEmpty ? [display.activeID].compactMap { $0 } : display.selectedIDs
        let active = ids.isEmpty ? [] : display.sentences.filter { ids.contains($0.id) }
        let visibleIDs = active.map(\.id)
        if displayedSentenceIDs != visibleIDs {
            displayedSentenceIDs = visibleIDs
            var selections = [PDFSelection]()
            for sentence in active {
                guard let page = view.document?.page(at: sentence.pageIndex) else { continue }
                selections += sentence.characterRanges.compactMap { page.selection(for: $0) }
            }
            for selection in selections {
                #if os(macOS)
                    selection.color = NSColor(calibratedRed: 0.73, green: 0.41, blue: 0.26, alpha: 0.25)
                #else
                    selection.color = UIColor(red: 0.73, green: 0.41, blue: 0.26, alpha: 0.25)
                #endif
            }
            view.highlightedSelections = selections
        }
        let newFocus = revealRevision != display.revealRevision
        let newScroll = scrollRevision != display.scrollRevision
        revealRevision = display.revealRevision
        scrollRevision = display.scrollRevision
        if let item = display.illustration, revealedIllustrationID != item.id,
            let page = view.document?.page(at: item.pageIndex)
        {
            view.go(to: item.sourceBounds, on: page)
        }
        revealedIllustrationID = display.illustration?.id
        let targetID = newFocus ? display.focusedID : (newScroll ? display.scrollID : nil)
        if let targetID, let sentence = display.sentences.first(where: { $0.id == targetID }),
            let page = view.document?.page(at: sentence.pageIndex),
            let firstRect = sentence.rects.first.flatMap(Self.rectangle),
            !view.bounds.contains(view.convert(firstRect, from: page))
        {
            view.go(to: firstRect.insetBy(dx: -8, dy: -12), on: page)
        }
    }

    @objc private func originalScrolled() {
        let session = model.pdfBilingual
        guard !isUpdating, session.matches(model), session.followsScroll, let view,
            let page = view.document?.page(at: session.pageIndex)
        else { return }
        let visible = view.convert(view.bounds, to: page)
        let referenceY = visible.maxY - visible.height * 0.3
        var nearest: (id: String, distance: CGFloat)?
        for sentence in session.sentences {
            for rect in sentence.rects.compactMap(Self.rectangle) where visible.intersects(rect) {
                let distance = abs(rect.midY - referenceY)
                if distance < nearest?.distance ?? .infinity { nearest = (sentence.id, distance) }
            }
        }
        if let nearest { session.scrollFromPDF(nearest.id) }
    }

    @objc func selectionChanged() {
        guard !isUpdating, paperID == model.selectedPaperID, keys == model.pageKeys else { return }
        guard let view, let selected = view.currentSelection, let page = selected.pages.first,
            let document = view.document, let text = selected.string,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            model.pdfBilingual.selectFromPDF([])
            model.captureSelection(text: "", rects: [], page: model.visiblePage)
            return
        }
        let lines = selected.selectionsByLine().filter { $0.pages.contains(page) }
        let rects = lines.map { line -> [Double] in
            let r = line.bounds(for: page)
            return [r.minX, r.minY, r.width, r.height]
        }
        let pageIndex = document.index(for: page)
        guard let captured = displayedDocument?.text(for: selected, on: pageIndex),
            !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            model.pdfBilingual.selectFromPDF([])
            model.captureSelection(text: "", rects: [], page: model.visiblePage)
            return
        }
        let ranges = (0..<selected.numberOfTextRanges(on: page)).map { selected.range(at: $0, on: page) }
        if model.pdfBilingual.matches(model), pageIndex == model.pdfBilingual.pageIndex {
            let matching = model.pdfBilingual.sentences.filter { sentence in
                sentence.characterRanges.contains { source in
                    ranges.contains { NSIntersectionRange($0, source).length > 0 }
                }
            }
            model.pdfBilingual.selectFromPDF(matching.map(\.id))
        }
        model.captureSelection(
            text: captured, rects: rects, page: pageIndex, spansPages: selected.pages.count > 1, ranges: ranges)
        if selected.pages.count > 1 { model.status = "跨页选择暂按第一页记录；请逐页划线以保留准确位置" }
    }

    private func selectedSourceText() -> String? {
        guard let view, let selection = view.currentSelection, let document = view.document,
            let displayedDocument
        else { return nil }
        var parts: [String] = []
        for page in selection.pages.sorted(by: { document.index(for: $0) < document.index(for: $1) }) {
            guard let text = displayedDocument.text(for: selection, on: document.index(for: page)) else { return nil }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }

    @objc func pageChanged() {
        guard !isUpdating, paperID == model.selectedPaperID, keys == model.pageKeys,
            let view, let page = view.currentPage, let document = view.document
        else { return }
        model.recordVisiblePage(document.index(for: page))
        model.touch()
    }

    private func inkURL(_ key: String, ext: String) -> URL? {
        guard let paperID else { return nil }
        return model.root.appendingPathComponent("Papers/\(paperID.uuidString)/Ink/\(key).\(ext)")
    }

    #if os(macOS)
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
            guard let index = view.document?.index(for: page), keys.indices.contains(index),
                let url = inkURL(keys[index], ext: "png"), let image = NSImage(contentsOf: url)
            else { return nil }
            let imageView = NSImageView(frame: page.bounds(for: .mediaBox))
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            return imageView
        }
    #else
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let index = view.document?.index(for: page), keys.indices.contains(index) else { return nil }
            let key = keys[index]
            if let canvas = canvases[key] { return canvas }
            let canvas = PKCanvasView(frame: page.bounds(for: .mediaBox))
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.drawingPolicy = .pencilOnly
            canvas.isUserInteractionEnabled = penEnabled
            canvas.tool = PKInkingTool(.pen, color: .systemTeal, width: 2)
            if let url = inkURL(key, ext: "drawing"), let data = try? Data(contentsOf: url),
                let drawing = try? PKDrawing(data: data)
            {
                canvas.drawing = drawing
            }
            canvas.delegate = self
            canvases[key] = canvas
            toolPicker.addObserver(canvas)
            return canvas
        }
        func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            if penEnabled, let canvas = overlayView as? PKCanvasView {
                toolPicker.setVisible(true, forFirstResponder: canvas)
                canvas.becomeFirstResponder()
            }
        }
    #endif
}

#if os(iOS)
    extension PDFCoordinator: PKCanvasViewDelegate {
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let key = canvases.first(where: { $0.value === canvasView })?.key,
                let drawingURL = inkURL(key, ext: "drawing"), let imageURL = inkURL(key, ext: "png")
            else { return }
            do {
                try FileManager.default.createDirectory(
                    at: drawingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try canvasView.drawing.dataRepresentation().write(to: drawingURL, options: .atomic)
                let image = canvasView.drawing.image(from: canvasView.bounds, scale: 2)
                if let png = image.pngData() { try png.write(to: imageURL, options: .atomic) }
                model.touch()
            } catch { model.message = "手写批注保存失败：\(error.localizedDescription)" }
        }
    }
#endif

#if os(iOS)
    extension PDFCoordinator: UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            model.pdfBilingual.matches(model) && !penEnabled
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
#endif
