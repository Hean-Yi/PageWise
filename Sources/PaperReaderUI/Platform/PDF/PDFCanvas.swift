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
        PDFInkColor(
            red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    /// Notes made before PDF character anchors were recorded keep their original system ink.
    fileprivate var legacyPDFInk: PDFInkColor {
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

struct PDFSelectionToolsAnchor: Equatable {
    let bounds: CGRect
    let paperID: UUID
    let page: Int
    let ranges: [NSRange]
    let text: String

    @MainActor func matches(_ model: ReaderModel) -> Bool {
        model.selectedPaperID == paperID && model.selectionPage == page && model.pdfSelectionRanges == ranges
            && model.selectionText == text && !model.pdfSelectionSpansPages
    }
}

struct PDFCanvas: View {
    let model: ReaderModel
    var penEnabled: Bool
    var isReaderVisible = true
    @State private var selectionAnchor: PDFSelectionToolsAnchor?
    @State private var hasPresentedTools = false
    var displayContext: PDFDisplayContext {
        PDFDisplayContext(
            isVisible: isReaderVisible,
            illustration: isReaderVisible && model.pdfBilingual.matches(model)
                ? model.pdfBilingual.sourceIllustration : nil)
    }
    var body: some View {
        PlatformPDF(model: model, penEnabled: penEnabled, focus: displayContext, selectionAnchor: $selectionAnchor)
            .overlay {
                if hasPresentedTools, isReaderVisible, !penEnabled {
                    let active = selectionAnchor.flatMap { $0.matches(model) && model.pdfNoteEditor == nil ? $0 : nil }
                    if model.mode == "original" {
                        PDFSelectionTools(model: model, selection: active) { selectionAnchor = nil }
                    } else if let active {
                        // A saved fixed-layout edition has its own page coordinates.
                        PDFSelectionToolsLayout(anchor: active.bounds) {
                            Button("高亮") {
                                guard active.matches(model) else { return }
                                model.highlightSelection()
                                selectionAnchor = nil
                            }
                            .readerIconButtonStyle(.plain).padding(8)
                            .readerGlassSurface(in: RoundedRectangle(cornerRadius: 9), bordered: true)
                        }
                    }
                }
            }
            .onChange(of: selectionAnchor) { _, anchor in
                if anchor != nil { hasPresentedTools = true }
            }
            .onChange(of: isReaderVisible) { _, _ in selectionAnchor = nil }
            .onChange(of: penEnabled) { _, _ in selectionAnchor = nil }
            .onChange(of: model.selectedPaperID) { _, _ in selectionAnchor = nil }
            .onChange(of: model.mode) { _, _ in selectionAnchor = nil }
            .quickStartTarget(
                isReaderVisible && model.mode == "original" && !model.hasPDFNoteSelection ? .annotation : nil)
    }
}

struct PDFDisplayContext {
    let isVisible: Bool
    let illustration: PDFReadingIllustration?
}

@MainActor
private final class ReaderPDFView: PDFView {
    var copyTextProvider: (() -> String?)?

    #if os(macOS)
        var notePointer: ((CGPoint) -> Void)?
        var dismissTools: (() -> Void)?
        var observesNoteInput = false
        private var clickStart: CGPoint?
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            guard window != nil else { return }
            // PDFKit's inner document view handles mouse tracking itself. Observe this window's
            // events without consuming them so text selection, links and scrolling keep working.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) {
                [weak self] event in
                guard let self, let window = self.window,
                    event.window === window, window.attachedSheet == nil
                else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismissTools?() }
                    return event
                }
                let point = self.convert(event.locationInWindow, from: nil)
                let inside = self.visibleRect.contains(point)
                if event.type == .leftMouseDown {
                    let content = window.contentView
                    let hit = content.flatMap { $0.hitTest($0.convert(event.locationInWindow, from: nil)) }
                    let inPDF = inside && (hit?.isDescendant(of: self) == true || hit === self)
                    if !inside || inPDF { self.dismissTools?() }
                    self.clickStart = self.observesNoteInput && inPDF && event.clickCount == 1 ? point : nil
                } else {
                    defer { self.clickStart = nil }
                    guard inside, let start = self.clickStart, hypot(start.x - point.x, start.y - point.y) < 3 else {
                        return event
                    }
                    if self.observesNoteInput { self.notePointer?(point) }
                }
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
        let focus: PDFDisplayContext
        @Binding var selectionAnchor: PDFSelectionToolsAnchor?
        func makeCoordinator() -> PDFCoordinator {
            let coordinator = PDFCoordinator(model: model)
            coordinator.selectionAnchorChanged = { if selectionAnchor != $0 { selectionAnchor = $0 } }
            return coordinator
        }
        func makeNSView(context: Context) -> PDFView { context.coordinator.makeView() }
        static func dismantleNSView(_ view: PDFView, coordinator: PDFCoordinator) { coordinator.detachSelectionTools() }
        func updateNSView(_ view: PDFView, context: Context) {
            context.coordinator.update(view, penEnabled: false, focus: focus)
        }
    }
#else
    private struct PlatformPDF: UIViewRepresentable {
        let model: ReaderModel
        let penEnabled: Bool
        let focus: PDFDisplayContext
        @Binding var selectionAnchor: PDFSelectionToolsAnchor?
        func makeCoordinator() -> PDFCoordinator {
            let coordinator = PDFCoordinator(model: model)
            coordinator.selectionAnchorChanged = { if selectionAnchor != $0 { selectionAnchor = $0 } }
            return coordinator
        }
        func makeUIView(context: Context) -> PDFView { context.coordinator.makeView() }
        static func dismantleUIView(_ view: PDFView, coordinator: PDFCoordinator) { coordinator.detachSelectionTools() }
        func updateUIView(_ view: PDFView, context: Context) {
            context.coordinator.update(view, penEnabled: penEnabled, focus: focus)
        }
    }
#endif

@MainActor
final class PDFCoordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    let model: ReaderModel
    weak var view: PDFView?
    fileprivate var selectionAnchorChanged: ((PDFSelectionToolsAnchor?) -> Void)?
    private var selectionToolsTask: Task<Void, Never>?
    var displayedDocument: PDFDisplayDocument?
    var displayedURLs: [URL]?
    var keys: [String] = []
    private var renderedHighlights: [String: [Highlight]] = [:]
    private var highlightInk: [String: [PDFAnnotation]] = [:]
    private struct NoteLocation {
        let page: PDFPage
        let bounds: CGRect
        let ink: [PDFAnnotation]
    }
    private var noteAnnotations: [UUID: [NoteLocation]] = [:]
    var penEnabled = false
    private var isVisible = false
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
            view.notePointer = { [weak self] point in self?.openNote(at: point) }
            view.dismissTools = { [weak self] in self?.dismissSelectionTools() }
        #else
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedPDF(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
        #endif
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
        NotificationCenter.default.addObserver(
            self, selector: #selector(dismissSelectionTools), name: .PDFViewScaleChanged, object: view)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        return view
    }

    func update(_ view: PDFView, penEnabled: Bool, focus: PDFDisplayContext) {
        isUpdating = true
        defer { isUpdating = false }
        let becameVisible = focus.isVisible && !isVisible
        isVisible = focus.isVisible
        self.penEnabled = penEnabled
        view.isInMarkupMode = penEnabled
        // SwiftUI can still update this representable while it is being replaced by the loading view.
        guard model.showsPDFCanvas, let currentPaperID = model.selectedPaperID else {
            view.document = nil
            displayedDocument = nil
            displayedURLs = nil
            keys = []
            paperID = nil
            renderedHighlights = [:]
            highlightInk = [:]
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
                renderedHighlights = [:]
                highlightInk = [:]
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
            renderedHighlights = [:]
            highlightInk = [:]
            noteAnnotations = [:]
            if let page = document.page(at: min(oldPage, max(0, document.pageCount - 1))) { view.go(to: page) }
        }
        if let document = view.document {
            updateHighlights(in: document)
            updateNotes(in: document)
        }
        #if os(macOS)
            (view as? ReaderPDFView)?.observesNoteInput =
                isVisible && (!noteAnnotations.isEmpty || !renderedHighlights.isEmpty)
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
        if isVisible {
            if let item = focus.illustration, becameVisible || revealedIllustrationID != item.id,
                let page = view.document?.page(at: item.pageIndex)
            {
                view.go(to: item.sourceBounds, on: page)
            }
            revealedIllustrationID = focus.illustration?.id
        }
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

    /// Keep the PDF's own ink intact. Rebuild changed pages so a partial erase or recolor can expose earlier marks.
    private func updateHighlights(in document: PDFDocument) {
        let updated = Dictionary(grouping: model.currentHighlights.filter { !$0.rects.isEmpty }, by: \.pageKey)
        guard updated != renderedHighlights else { return }
        let changed = Set(updated.keys).union(renderedHighlights.keys).filter { updated[$0] != renderedHighlights[$0] }
        defer { renderedHighlights = updated }
        for key in changed {
            guard let index = keys.firstIndex(of: key), let page = document.page(at: index) else { continue }
            let before = renderedHighlights[key] ?? []
            let after = updated[key] ?? []
            let appended = after.starts(with: before)
            if !appended {
                for ink in highlightInk.removeValue(forKey: key) ?? [] { page.removeAnnotation(ink) }
                // An existing note underline may become visible after an overlapping mark is erased.
                let affectedNotes = noteAnnotations.compactMap { id, hits in
                    hits.contains { $0.page === page } ? id : nil
                }
                for id in affectedNotes { removeNoteInk(id) }
            }
            let drawnNotes = Set(noteAnnotations.values.flatMap { $0 }.flatMap(\.ink).map(ObjectIdentifier.init))
            var covered = page.annotations.filter {
                ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains($0.type ?? "")
                    && !drawnNotes.contains(ObjectIdentifier($0))
            }.flatMap(Self.markupBounds)
            for mark in after.dropFirst(appended ? before.count : 0) {
                let style = mark.style ?? .highlight
                let pigment = mark.color ?? .yellow
                let color = mark.pdfTextStart == nil ? pigment.legacyPDFInk : pigment.pdfInk
                let alpha: CGFloat = mark.pdfTextStart == nil ? 0.45 : 0.65
                for box in mark.rects.compactMap(Self.rectangle) {
                    for rect in PDFHighlightCoverage.uncovered(box, by: covered) {
                        let ink = PDFAnnotation(
                            bounds: rect, forType: style == .underline ? .underline : .highlight,
                            withProperties: nil)
                        ink.color = color.withAlphaComponent(style == .underline ? 1 : alpha)
                        page.addAnnotation(ink)
                        highlightInk[key, default: []].append(ink)
                        covered.append(rect)
                    }
                }
            }
        }
    }

    private func removeNoteInk(_ id: UUID) {
        for location in noteAnnotations.removeValue(forKey: id) ?? [] {
            for annotation in location.ink { location.page.removeAnnotation(annotation) }
        }
    }

    private func updateNotes(in document: PDFDocument) {
        let notes = model.inlinePDFNotes
        let live = Set(notes.map(\.id))
        for id in noteAnnotations.keys where !live.contains(id) {
            removeNoteInk(id)
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
        guard isVisible, !penEnabled, let view, let document = view.document,
            let page = view.page(for: point, nearest: false)
        else { return false }
        let location = view.convert(point, to: page)
        if let hit = model.inlinePDFNotes.first(where: { note in
            noteAnnotations[note.id]?.contains { $0.page === page && $0.bounds.contains(location) } == true
        }), let note = model.currentReadingNotes.first(where: { $0.id == hit.id }) {
            model.openReadingNote(note, onOriginalPDF: true)
            return true
        }
        let index = document.index(for: page)
        guard model.mode == "original",
            let mark = renderedHighlights["original-\(index)"]?.last(where: { mark in
                mark.rects.contains { Self.rectangle($0)?.contains(location) == true }
            })
        else { return false }
        model.openPDFHighlightNote(mark)
        return true
    }

    #if os(iOS)
        @objc private func tappedPDF(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended, let view { openNote(at: gesture.location(in: view)) }
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

    @objc private func originalScrolled() {
        selectionAnchorChanged?(nil)
    }

    @objc func selectionChanged() {
        guard isVisible, !isUpdating, paperID == model.selectedPaperID, keys == model.pageKeys else { return }
        dismissSelectionTools()
        guard let view, let selected = view.currentSelection, let page = selected.pages.first,
            let document = view.document, let text = selected.string,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
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
            model.captureSelection(text: "", rects: [], page: model.visiblePage)
            return
        }
        let ranges = (0..<selected.numberOfTextRanges(on: page)).map { selected.range(at: $0, on: page) }
        model.captureSelection(
            text: captured, rects: rects, page: pageIndex, spansPages: selected.pages.count > 1, ranges: ranges)
        if selected.pages.count > 1 {
            model.status = "跨页选择暂按第一页记录；请逐页划线以保留准确位置"
        } else if !ranges.isEmpty && !rects.isEmpty && !penEnabled && selectionAnchorChanged != nil {
            selectionToolsTask = Task { @MainActor [weak self, weak view] in
                #if os(macOS)
                    // PDFKit tracks the mouse in its own document subview and may update the selection on every drag.
                    while NSEvent.pressedMouseButtons & 1 != 0 {
                        do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
                    }
                #else
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                #endif
                guard !Task.isCancelled, let self, let view, isVisible, !penEnabled,
                    let paperID, paperID == model.selectedPaperID, keys == model.pageKeys,
                    view.currentSelection != nil, model.selectionPage == pageIndex,
                    model.selectionText == captured, model.pdfSelectionRanges == ranges
                else { return }
                guard
                    let area = lines.reversed().lazy.map({
                        view.convert($0.bounds(for: page), from: page).intersection(view.bounds)
                    }).first(where: { !$0.isNull && !$0.isEmpty })
                else { return }
                #if os(macOS)
                    let y = view.isFlipped ? area.minY - view.bounds.minY : view.bounds.maxY - area.maxY
                #else
                    let y = area.minY - view.bounds.minY
                #endif
                let bounds = CGRect(x: area.minX - view.bounds.minX, y: y, width: area.width, height: area.height)
                selectionAnchorChanged?(
                    .init(bounds: bounds, paperID: paperID, page: pageIndex, ranges: ranges, text: captured))
            }
        }
    }

    @objc private func dismissSelectionTools() {
        selectionToolsTask?.cancel()
        selectionToolsTask = nil
        selectionAnchorChanged?(nil)
    }

    fileprivate func detachSelectionTools() {
        selectionAnchorChanged = nil
        dismissSelectionTools()
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
        guard let paperID, model.lastPaperDeletion[paperID] == nil else { return nil }
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
            isVisible && (!renderedHighlights.isEmpty || !noteAnnotations.isEmpty) && !penEnabled
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
#endif
