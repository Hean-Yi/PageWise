import PDFKit
import PaperReaderKit
import SwiftUI

#if os(iOS)
    import PencilKit
#endif

struct PDFCanvas: View {
    let model: ReaderModel
    var penEnabled: Bool
    var body: some View {
        PlatformPDF(model: model, penEnabled: penEnabled)
    }
}

@MainActor
private final class ReaderPDFView: PDFView {
    var copyTextProvider: (() -> String?)?

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
        func makeCoordinator() -> PDFCoordinator { PDFCoordinator(model: model) }
        func makeNSView(context: Context) -> PDFView { context.coordinator.makeView() }
        func updateNSView(_ view: PDFView, context: Context) { context.coordinator.update(view, penEnabled: false) }
    }
#else
    private struct PlatformPDF: UIViewRepresentable {
        let model: ReaderModel
        let penEnabled: Bool
        func makeCoordinator() -> PDFCoordinator { PDFCoordinator(model: model) }
        func makeUIView(context: Context) -> PDFView { context.coordinator.makeView() }
        func updateUIView(_ view: PDFView, context: Context) {
            context.coordinator.update(view, penEnabled: penEnabled)
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
        view.displaysPageBreaks = true
        view.pageOverlayViewProvider = self
        #if os(macOS)
            view.acceptsDraggedFiles = false
            view.backgroundColor = NSColor(ReaderTheme.canvas)
        #else
            view.backgroundColor = UIColor.secondarySystemBackground
        #endif
        self.view = view
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        return view
    }

    func update(_ view: PDFView, penEnabled: Bool) {
        isUpdating = true
        defer { isUpdating = false }
        self.penEnabled = penEnabled
        view.isInMarkupMode = penEnabled
        // SwiftUI may update the old representable once after the reader is dismissed.
        guard model.paper != nil else {
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
            let oldPage = identity.isEmpty ? 0 : model.visiblePage
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
                Task { @MainActor [weak model] in model?.message = message }
                return
            }
            view.document = document
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

    @objc func selectionChanged() {
        guard !isUpdating, paperID == model.selectedPaperID, keys == model.pageKeys else { return }
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
        model.captureSelection(text: captured, rects: rects, page: pageIndex)
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
