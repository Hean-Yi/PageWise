import CoreGraphics
import PDFKit

/// Permits only explicitly recognizable decoration. Figures, images, equations and Form XObjects
/// remain unsupported so their visual information cannot disappear in a text-only rendition.
enum PDFGraphicsInspector {
    private struct GraphicsState {
        var transform = CGAffineTransform.identity
        var fillIsWhite = false
        var fillColorSpace = "DeviceGray"
        var lineWidth: CGFloat = 1
    }

    private struct ScanState {
        let pageBounds: CGRect
        var graphics = GraphicsState()
        var stack: [GraphicsState] = []
        var points: [CGPoint] = []
        var isSingleRectangle = false
        var complexPath = false
        var unsupported = false
        var headerRules = 0
        var hasText = false

        mutating func resetPath() {
            points = []
            isSingleRectangle = false
            complexPath = false
        }

        mutating func stroke() {
            let scale = max(
                hypot(graphics.transform.a, graphics.transform.b), hypot(graphics.transform.c, graphics.transform.d))
            let isRule: Bool
            if points.count == 2, let first = points.first, let last = points.last {
                let isHorizontal = abs(first.y - last.y) <= 0.5
                let isMargin = first.y > pageBounds.maxY - 70 || first.y < pageBounds.minY + 60
                isRule =
                    !complexPath && isHorizontal && isMargin && abs(first.x - last.x) >= pageBounds.width * 0.5
                    && graphics.lineWidth * scale <= 1.5
            } else {
                isRule = false
            }
            if isRule { headerRules += 1 } else { unsupported = true }
            if headerRules > 2 { unsupported = true }
            resetPath()
        }

        mutating func fill() {
            let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            let isBackground =
                !hasText && isSingleRectangle && !complexPath && graphics.fillIsWhite
                && abs(bounds.minX - pageBounds.minX) < 1 && abs(bounds.minY - pageBounds.minY) < 1
                && abs(bounds.width - pageBounds.width) < 1 && abs(bounds.height - pageBounds.height) < 1
            if !isBackground { unsupported = true }
            resetPath()
        }
    }

    static func containsUnsupportedGraphics(_ page: PDFPage) -> Bool {
        guard let pageRef = page.pageRef, let table = CGPDFOperatorTableCreate() else { return true }
        for operation in ["Do", "BI", "sh", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, operation) { _, info in
                PDFGraphicsInspector.state(info)?.pointee.unsupported = true
            }
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in PDFGraphicsInspector.state(info)?.pointee.hasText = true
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let state = PDFGraphicsInspector.state(info) else { return }
            state.pointee.stack.append(state.pointee.graphics)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let state = PDFGraphicsInspector.state(info) else { return }
            if let saved = state.pointee.stack.popLast() {
                state.pointee.graphics = saved
            } else {
                state.pointee.unsupported = true
            }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let state = PDFGraphicsInspector.state(info),
                let values = PDFGraphicsInspector.numbers(scanner, count: 6)
            else { return }
            let transform = CGAffineTransform(
                a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            state.pointee.graphics.transform = transform.concatenating(state.pointee.graphics.transform)
        }
        CGPDFOperatorTableSetCallback(table, "w") { scanner, info in
            guard let values = PDFGraphicsInspector.numbers(scanner, count: 1) else { return }
            PDFGraphicsInspector.state(info)?.pointee.graphics.lineWidth = values[0]
        }
        for operation in ["m", "l"] {
            CGPDFOperatorTableSetCallback(table, operation) { scanner, info in
                guard let state = PDFGraphicsInspector.state(info),
                    let values = PDFGraphicsInspector.numbers(scanner, count: 2)
                else { return }
                state.pointee.isSingleRectangle = false
                let point = CGPoint(x: values[0], y: values[1]).applying(state.pointee.graphics.transform)
                state.pointee.points.append(point)
            }
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let state = PDFGraphicsInspector.state(info),
                let values = PDFGraphicsInspector.numbers(scanner, count: 4)
            else { return }
            state.pointee.isSingleRectangle = state.pointee.points.isEmpty
            let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            for point in [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            ] {
                state.pointee.points.append(point.applying(state.pointee.graphics.transform))
            }
        }
        for operation in ["c", "v", "y"] {
            CGPDFOperatorTableSetCallback(table, operation) { _, info in
                PDFGraphicsInspector.state(info)?.pointee.complexPath = true
            }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in PDFGraphicsInspector.state(info)?.pointee.resetPath() }
        for operation in ["S", "s"] {
            CGPDFOperatorTableSetCallback(table, operation) { _, info in
                PDFGraphicsInspector.state(info)?.pointee.stroke()
            }
        }
        for operation in ["f", "F", "f*"] {
            CGPDFOperatorTableSetCallback(table, operation) { _, info in
                PDFGraphicsInspector.state(info)?.pointee.fill()
            }
        }
        CGPDFOperatorTableSetCallback(table, "g") { scanner, info in
            guard let values = PDFGraphicsInspector.numbers(scanner, count: 1) else { return }
            PDFGraphicsInspector.state(info)?.pointee.graphics.fillIsWhite = values[0] >= 0.98
            PDFGraphicsInspector.state(info)?.pointee.graphics.fillColorSpace = "DeviceGray"
        }
        CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in
            guard let values = PDFGraphicsInspector.numbers(scanner, count: 3) else { return }
            PDFGraphicsInspector.state(info)?.pointee.graphics.fillIsWhite = values.allSatisfy { $0 >= 0.98 }
            PDFGraphicsInspector.state(info)?.pointee.graphics.fillColorSpace = "DeviceRGB"
        }
        CGPDFOperatorTableSetCallback(table, "k") { scanner, info in
            guard let values = PDFGraphicsInspector.numbers(scanner, count: 4) else { return }
            PDFGraphicsInspector.state(info)?.pointee.graphics.fillIsWhite = values.allSatisfy { $0 <= 0.02 }
            PDFGraphicsInspector.state(info)?.pointee.graphics.fillColorSpace = "DeviceCMYK"
        }
        CGPDFOperatorTableSetCallback(table, "cs") { scanner, info in
            guard let state = PDFGraphicsInspector.state(info) else { return }
            var name: UnsafePointer<CChar>?
            state.pointee.graphics.fillIsWhite = false
            if CGPDFScannerPopName(scanner, &name), let name {
                state.pointee.graphics.fillColorSpace = PDFGraphicsInspector.colorSpace(named: name, scanner: scanner)
            } else {
                state.pointee.graphics.fillColorSpace = "unknown"
            }
        }
        for operation in ["sc", "scn"] {
            CGPDFOperatorTableSetCallback(table, operation) { scanner, info in
                guard let state = PDFGraphicsInspector.state(info) else { return }
                let space = state.pointee.graphics.fillColorSpace
                let count = space == "DeviceGray" ? 1 : (space == "DeviceRGB" ? 3 : (space == "DeviceCMYK" ? 4 : 0))
                guard count > 0, let values = PDFGraphicsInspector.numbers(scanner, count: count) else {
                    state.pointee.graphics.fillIsWhite = false
                    return
                }
                state.pointee.graphics.fillIsWhite =
                    space == "DeviceCMYK"
                    ? values.allSatisfy { $0 <= 0.02 } : values.allSatisfy { $0 >= 0.98 }
            }
        }

        let content = CGPDFContentStreamCreateWithPage(pageRef)
        var scanState = ScanState(pageBounds: page.bounds(for: .mediaBox))
        // The callback state is local to this synchronous scan; no shared mutable state escapes.
        let scanned = withUnsafeMutablePointer(to: &scanState) { pointer in
            CGPDFScannerScan(CGPDFScannerCreate(content, table, pointer))
        }
        return scanState.unsupported || !scanned
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<ScanState>? {
        info?.assumingMemoryBound(to: ScanState.self)
    }

    private static func colorSpace(named name: UnsafePointer<CChar>, scanner: CGPDFScannerRef) -> String {
        let direct = String(cString: name)
        if ["DeviceGray", "DeviceRGB", "DeviceCMYK"].contains(direct) { return direct }
        let content = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(content, "ColorSpace", name) else { return "unknown" }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array else { return "unknown" }
        var kind: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &kind), let kind else { return "unknown" }
        if String(cString: kind) == "CalGray" { return "DeviceGray" }
        if String(cString: kind) == "CalRGB" { return "DeviceRGB" }
        guard String(cString: kind) == "ICCBased" else { return "unknown" }
        var stream: CGPDFStreamRef?
        guard CGPDFArrayGetStream(array, 1, &stream), let stream,
            let dictionary = CGPDFStreamGetDictionary(stream)
        else { return "unknown" }
        var components: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "N", &components) else { return "unknown" }
        switch components {
        case 1: return "DeviceGray"
        case 3: return "DeviceRGB"
        case 4: return "DeviceCMYK"
        default: return "unknown"
        }
    }

    private static func numbers(_ scanner: CGPDFScannerRef, count: Int) -> [CGFloat]? {
        var result: [CGFloat] = []
        for _ in 0..<count {
            var number: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &number) else { return nil }
            result.append(CGFloat(number))
        }
        return Array(result.reversed())
    }
}
