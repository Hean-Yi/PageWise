import PDFKit
import PaperReaderKit
import SwiftUI

#if os(macOS)
    private typealias PDFInkColor = NSColor
#else
    private typealias PDFInkColor = UIColor
#endif

extension AnnotationColor {
    fileprivate var pdfInk: PDFInkColor {
        switch self {
        case .yellow: .systemYellow
        case .red: .systemRed
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .orange: .systemOrange
        case .gray: .systemGray
        }
    }
}

#if os(iOS)
    import PencilKit
#endif

struct PDFCanvas: View {
    let model: ReaderModel
    var penEnabled: Bool
    var acceptsSentenceInput = true
    var sentenceDisplay: PDFSentenceDisplay {
        let session = model.pdfBilingual
        return PDFSentenceDisplay(
            isVisible: acceptsSentenceInput,
            sentences: session.matches(model) && acceptsSentenceInput ? session.sentences : [],
            activeID: session.activeID,
            focusedID: session.focusedID, revealRevision: session.revealRevision,
            selectedIDs: session.translationSelectedIDs, scrollID: session.pdfScrollID,
            scrollRevision: session.pdfScrollRevision,
            illustration: acceptsSentenceInput && session.matches(model) ? session.sourceIllustration : nil)
    }
    var body: some View {
        PlatformPDF(model: model, penEnabled: penEnabled, focus: sentenceDisplay)
    }
}

struct PDFSentenceDisplay {
    let isVisible: Bool
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
        var notePointer: ((CGPoint) -> Void)?
        var observesNoteInput = false
        private var noteClickStart: CGPoint?
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
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved]) {
                [weak self] event in
                guard let self, self.observesSentenceInput || self.observesNoteInput, let window = self.window,
                    event.window === window, window.attachedSheet == nil
                else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                let inside = self.visibleRect.contains(point)
                if self.observesNoteInput && event.type == .leftMouseDown {
                    let content = window.contentView
                    let hit = content.flatMap { $0.hitTest($0.convert(event.locationInWindow, from: nil)) }
                    self.noteClickStart =
                        inside && event.clickCount == 1 && (hit?.isDescendant(of: self) == true || hit === self)
                        ? point : nil
                }
                if event.type == .leftMouseUp {
                    if self.observesNoteInput, inside, let start = self.noteClickStart,
                        hypot(start.x - point.x, start.y - point.y) < 3
                    {
                        self.notePointer?(point)
                    }
                    self.noteClickStart = nil
                    return event
                }
                if inside && self.observesSentenceInput {
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
final class PDFCoordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    let model: ReaderModel
    weak var view: PDFView?
    var displayedDocument: PDFDisplayDocument?
    var displayedURLs: [URL]?
    var keys: [String] = []
    var highlightIDs: Set<UUID> = []
    private struct NoteLocation {
        let page: PDFPage
        let bounds: CGRect
        let ink: [PDFAnnotation]
    }
    private var noteAnnotations: [UUID: [NoteLocation]] = [:]
    var penEnabled = false
    private var isVisible = false
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
            view.notePointer = { [weak self] point in self?.openNote(at: point) }
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
        let becameVisible = focus.isVisible && !isVisible
        isVisible = focus.isVisible
        self.penEnabled = penEnabled
        #if os(macOS)
            (view as? ReaderPDFView)?.observesSentenceInput = !focus.sentences.isEmpty
        #endif
        view.isInMarkupMode = penEnabled
        // SwiftUI can still update this representable while it is being replaced by the loading view.
        guard model.showsPDFCanvas, let currentPaperID = model.selectedPaperID else {
            view.document = nil
            displayedDocument = nil
            displayedURLs = nil
            keys = []
            paperID = nil
            highlightIDs = []
            noteAnnotations = [:]
            #if os(iOS)
                for canvas in canvases.values {
                    toolPicker.setVisible(false, forFirstResponder: canvas)
                    toolPicker.removeObserver(canvas)
                }
                canvases = [:]
            #endif
            return
        }
        let urls = model.pageURLs
        if displayedURLs != urls || paperID != currentPaperID {
            let oldPage = model.visiblePage
            displayedSentenceIDs = []
            revealRevision = nil
            revealedIllustrationID = nil
            displayedURLs = urls
            keys = model.pageKeys
            paperID = currentPaperID
            #if os(iOS)
                for canvas in canvases.values { toolPicker.removeObserver(canvas) }
                canvases = [:]
            #endif
            let document: PDFDocument
            do {
                let loaded = try PDFDisplayDocument.load(urls: urls, expectedPageCount: keys.count)
                displayedDocument = loaded
                document = loaded.document
            } catch {
                view.document = nil
                displayedDocument = nil
                highlightIDs = []
                let message = error.localizedDescription
                Task { @MainActor [weak model, keys] in
                    guard let model, model.showsPDFCanvas, model.selectedPaperID == currentPaperID,
                        model.pageURLs == urls, model.pageKeys == keys
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
            noteAnnotations = [:]
            if let page = document.page(at: min(oldPage, max(0, document.pageCount - 1))) { view.go(to: page) }
        }
        for mark in model.currentHighlights where !highlightIDs.contains(mark.id) {
            guard let index = keys.firstIndex(of: mark.pageKey), let page = view.document?.page(at: index) else {
                continue
            }
            let style = mark.style ?? .highlight
            let color = (mark.color ?? .yellow).pdfInk.withAlphaComponent(style == .underline ? 1 : 0.45)
            let noteInk = Set(noteAnnotations.values.flatMap { $0 }.flatMap(\.ink).map(ObjectIdentifier.init))
            let existing = page.annotations.filter {
                ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains($0.type ?? "")
                    && !noteInk.contains(ObjectIdentifier($0))
            }.flatMap(Self.markupBounds)
            for rect in mark.rects.compactMap(Self.rectangle).flatMap({
                PDFHighlightCoverage.uncovered($0, by: existing)
            }) {
                let annotation = PDFAnnotation(
                    bounds: rect, forType: style == .underline ? .underline : .highlight, withProperties: nil)
                annotation.color = color
                page.addAnnotation(annotation)
            }
            highlightIDs.insert(mark.id)
        }
        if let document = view.document { updateNotes(in: document) }
        #if os(macOS)
            (view as? ReaderPDFView)?.observesNoteInput = isVisible && !noteAnnotations.isEmpty
        #endif
        if isVisible, let index = model.jumpPage, let page = view.document?.page(at: index) {
            let outline = model.jumpOutlineItem
            view.clearSelection()
            let requestedNote = model.pdfNoteEditor?.note
            let requestedAnchor = requestedNote?.id == model.requestedReadingNote ? requestedNote?.anchors.first : nil
            if let anchor = model.jumpPassageAnchors.first ?? requestedAnchor, anchor.pdfPageIndex == index,
                anchor.start >= 0, anchor.end > anchor.start, anchor.end <= page.numberOfCharacters,
                let selection = page.selection(for: NSRange(location: anchor.start, length: anchor.end - anchor.start))
            {
                view.go(to: selection.bounds(for: page).insetBy(dx: -10, dy: -18), on: page)
            } else if let id = model.requestedReadingNote, model.pdfNoteEditor?.id == id,
                let box = noteAnnotations[id]?.first(where: { $0.page === page })?.bounds
            {
                view.go(to: box.insetBy(dx: -10, dy: -18), on: page)
            } else if model.mode == "original", var point = outline?.sourcePoint {
                if outline?.sourceRange != nil {
                    point.y = min(page.bounds(for: view.displayBox).maxY, point.y + 10 / max(view.scaleFactor, 0.1))
                }
                view.go(to: PDFDestination(page: page, at: point))
            } else {
                view.go(to: page)
            }
            Task { @MainActor [weak self] in
                guard let self, self.isVisible, self.displayedURLs == urls, self.model.jumpPage == index,
                    self.model.jumpOutlineItem == outline,
                    self.paperID == self.model.selectedPaperID, self.keys == self.model.pageKeys
                else { return }
                self.model.recordVisiblePage(index)
                self.model.jumpPage = nil
            }
        } else if becameVisible, let page = view.document?.page(at: model.visiblePage), view.currentPage !== page {
            view.go(to: page)
        }
        if isVisible { updateSentenceFocus(in: view, display: focus, becameVisible: becameVisible) }
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

    private func updateNotes(in document: PDFDocument) {
        let notes = model.inlinePDFNotes
        let live = Set(notes.map(\.id))
        for id in noteAnnotations.keys where !live.contains(id) {
            for location in noteAnnotations.removeValue(forKey: id) ?? [] {
                for annotation in location.ink { location.page.removeAnnotation(annotation) }
            }
        }
        let missing = notes.filter { noteAnnotations[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let drawnInk = Set(noteAnnotations.values.flatMap { $0 }.flatMap(\.ink).map(ObjectIdentifier.init))
        var existingUnderlines: [Int: [CGRect]] = [:]
        for note in missing {
            var annotations: [NoteLocation] = []
            for anchor in note.anchors {
                guard let index = anchor.pdfPageIndex, keys.indices.contains(index), keys[index] == anchor.key,
                    let page = document.page(at: index), let raw = page.string as NSString?, anchor.start >= 0,
                    anchor.end > anchor.start, anchor.end <= raw.length
                else { continue }
                let range = NSRange(location: anchor.start, length: anchor.end - anchor.start)
                guard raw.substring(with: range) == anchor.text, let selection = page.selection(for: range) else {
                    continue
                }
                if existingUnderlines[index] == nil {
                    existingUnderlines[index] = page.annotations.filter {
                        $0.type == "Underline" && !drawnInk.contains(ObjectIdentifier($0))
                    }.flatMap(Self.markupBounds)
                }
                for line in selection.selectionsByLine() {
                    let box = line.bounds(for: page)
                    guard !box.isEmpty else { continue }
                    let ink = PDFHighlightCoverage.uncovered(box, by: existingUnderlines[index] ?? []).map { rect in
                        let annotation = PDFAnnotation(bounds: rect, forType: .underline, withProperties: nil)
                        annotation.color = PDFInkColor.systemBrown
                        page.addAnnotation(annotation)
                        return annotation
                    }
                    annotations.append(NoteLocation(page: page, bounds: box, ink: ink))
                }
            }
            noteAnnotations[note.id] = annotations
        }
    }

    @discardableResult
    func openNote(at point: CGPoint) -> Bool {
        guard isVisible, !penEnabled, !noteAnnotations.isEmpty, let view,
            let page = view.page(for: point, nearest: false)
        else { return false }
        let location = view.convert(point, to: page)
        guard
            let hit = model.inlinePDFNotes.first(where: { note in
                noteAnnotations[note.id]?.contains { $0.page === page && $0.bounds.contains(location) } == true
            }), let note = model.currentReadingNotes.first(where: { $0.id == hit.id })
        else { return false }
        model.openReadingNote(note)
        return true
    }

    private func sentence(at point: CGPoint) -> PDFSourceSentence? {
        guard isVisible, let view, !penEnabled, model.pdfBilingual.matches(model),
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
            if gesture.state == .ended, let view, !openNote(at: gesture.location(in: view)),
                let hit = sentence(at: gesture.location(in: view))
            {
                model.pdfBilingual.focusFromPDF(hit.id)
            }
        }
    #endif

    /// Embedded multi-line PDF markup can have one large bounding box and several separate glyph quads.
    private static func markupBounds(_ annotation: PDFAnnotation) -> [CGRect] {
        guard let values = annotation.quadrilateralPoints, !values.isEmpty, values.count.isMultiple(of: 4)
        else { return [annotation.bounds] }
        #if os(macOS)
            let points = values.map(\.pointValue)
        #else
            let points = values.map(\.cgPointValue)
        #endif
        let bounds = annotation.bounds
        return stride(from: 0, to: points.count, by: 4).map { start in
            let quad = points[start..<(start + 4)]
            let xs = quad.map(\.x)
            let ys = quad.map(\.y)
            let x = xs.min() ?? 0
            let y = ys.min() ?? 0
            return CGRect(
                x: bounds.minX + x, y: bounds.minY + y, width: (xs.max() ?? x) - x, height: (ys.max() ?? y) - y)
        }
    }

    private static func rectangle(_ values: [Double]) -> CGRect? {
        guard values.count == 4, values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private func updateSentenceFocus(in view: PDFView, display: PDFSentenceDisplay, becameVisible: Bool) {
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
        let newFocus = becameVisible || revealRevision != display.revealRevision
        let newScroll = becameVisible || scrollRevision != display.scrollRevision
        revealRevision = display.revealRevision
        scrollRevision = display.scrollRevision
        if let item = display.illustration {
            if becameVisible || revealedIllustrationID != item.id, let page = view.document?.page(at: item.pageIndex) {
                view.go(to: item.sourceBounds, on: page)
            }
            revealedIllustrationID = item.id
            return
        }
        revealedIllustrationID = nil
        let targetID = (newFocus ? display.focusedID : nil) ?? (newScroll ? display.scrollID : nil)
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
        guard isVisible, !isUpdating, session.matches(model), session.followsScroll, let view,
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
        guard isVisible, !isUpdating, paperID == model.selectedPaperID, keys == model.pageKeys else { return }
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
        guard isVisible, !isUpdating, model.jumpPage == nil, paperID == model.selectedPaperID, keys == model.pageKeys,
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
            (model.pdfBilingual.matches(model) || !noteAnnotations.isEmpty) && !penEnabled
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
#endif
