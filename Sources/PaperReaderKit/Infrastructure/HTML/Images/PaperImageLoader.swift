import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PaperImage: Sendable {
    let dataURI: String
    let width: Double
    let height: Double
    let notices: [String]
    var coverageText: String = ""
}

/// All decoders inspect file bytes. Extensions and Content-Type are not trusted as format evidence.
actor PaperImageLoader {
    private let source: URL
    private let transport: any HTTPTransport
    private var cache: [URL: [PaperImage]] = [:]
    private var loading: Set<URL> = []
    private var downloadedBytes = 0
    private var resourceCount = 0
    private var unavailableConnection: URLError?

    init(source: URL, transport: any HTTPTransport) {
        self.source = source
        self.transport = transport
    }

    func load(_ reference: String, relativeTo base: URL? = nil, depth: Int = 0) async throws -> [PaperImage] {
        try Task.checkCancellation()
        guard depth <= 3 else { throw ReaderError.message("图片嵌套层级过多，请查看原版。") }
        if reference.hasPrefix("data:") {
            guard let comma = reference.firstIndex(of: ",") else { throw ReaderError.message("内嵌图片格式无效。") }
            let header = reference[..<comma]
            let payload = String(reference[reference.index(after: comma)...])
            guard payload.utf8.count <= 12_000_000 else { throw ReaderError.message("内嵌图片过大。") }
            let data =
                header.hasSuffix(";base64")
                ? Data(base64Encoded: payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
            guard let data else { throw ReaderError.message("内嵌图片无法解码。") }
            return try await decode(data, at: base ?? source, depth: depth)
        }
        guard !reference.isEmpty,
            let url = URL(string: reference, relativeTo: base ?? source)?.absoluteURL.standardized,
            url.scheme == "https", url.host == source.host, url.user == nil, url.password == nil,
            url.port == nil || url.port == 443, url.query == nil, url.fragment == nil,
            url.path.hasPrefix(source.path + "/"), !url.path.split(separator: "/").contains("..")
        else { throw ReaderError.message("图片来源无法确认，请查看原版。") }
        if let found = cache[url] { return found }
        if let unavailableConnection { throw unavailableConnection }
        guard !loading.contains(url), resourceCount < 150 else { throw ReaderError.message("图片依赖循环或数量过多。") }
        loading.insert(url)
        resourceCount += 1
        defer { loading.remove(url) }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: URLRequest(url: url))
        } catch let error as URLError {
            // All accepted resources share one origin. A broken TLS/DNS/offline connection
            // must not incur the same network wait for every figure in this import.
            let connectionFailures: Set<URLError.Code> = [
                .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            ]
            if connectionFailures.contains(error.code) { unavailableConnection = error }
            throw error
        }
        try Task.checkCancellation()
        downloadedBytes += data.count
        guard response.statusCode == 200, response.url == url, data.count <= 12_000_000, downloadedBytes <= 60_000_000
        else {
            throw ReaderError.message("图片下载失败或资源过大，请查看原版。")
        }
        let result = try await decode(data, at: url, depth: depth)
        cache[url] = result
        return result
    }

    func inlineSVG(_ xml: String) async throws -> [PaperImage] {
        try await decode(Data(xml.utf8), at: source, depth: 0)
    }

    private func decode(_ data: Data, at url: URL, depth: Int) async throws -> [PaperImage] {
        guard data.count <= 12_000_000 else { throw ReaderError.message("图片资源过大。") }
        if data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil { return try Self.pdfImages(data) }
        if let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0 {
            return try Self.rasterImages(image)
        }
        if data.starts(with: Data("%!PS".utf8)) { throw ReaderError.message("EPS/PS 图片需查看原版。") }
        let svg = try SVGImageDocument.parse(data)
        var replacements: [String: String] = [:]
        var embeddedBytes = data.count
        var notices = svg.isAnimated ? ["动态图按静态底图呈现。"] : []
        var coverageText = svg.coverageText
        for reference in svg.imageReferences.sorted() {
            let nested = try await load(reference, relativeTo: url, depth: depth + 1)
            guard nested.count == 1 else { throw ReaderError.message("SVG 内的多页图片无法完整展开，请查看原版。") }
            embeddedBytes += nested[0].dataURI.utf8.count
            guard embeddedBytes <= 32_000_000 else { throw ReaderError.message("SVG 内嵌资源过大，请查看原版。") }
            replacements[reference] = nested[0].dataURI
            notices += nested[0].notices
            coverageText += " " + nested[0].coverageText
        }
        return [
            PaperImage(
                dataURI: try svg.dataURI(replacing: replacements), width: svg.width, height: svg.height,
                notices: notices, coverageText: coverageText)
        ]
    }

    private static func rasterImages(_ source: CGImageSource) throws -> [PaperImage] {
        let count = CGImageSourceGetCount(source)
        let type = CGImageSourceGetType(source) as String? ?? ""
        let animated =
            count > 1 && ["com.compuserve.gif", "public.png", "org.webmproject.webp", "public.webp"].contains(type)
        let frameCount = animated ? 1 : count
        guard frameCount <= 16 else { throw ReaderError.message("多页图片超过 16 页，请查看原版。") }
        var totalBytes = 0
        return try (0..<frameCount).map { index in
            try Task.checkCancellation()
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                width > 0, height > 0, width <= 30_000, height <= 30_000, width * height <= 80_000_000,
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, index,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4_096,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary)
            else { throw ReaderError.message("图片损坏、尺寸过大或设备不支持该格式，请查看原版。") }
            var notices = animated ? ["动态图仅显示首帧，完整动态内容请查看来源。"] : []
            if max(width, height) > 4_096 { notices.append("超大位图已按阅读分辨率缩小，细节请对照原版。") }
            let result = try png(image, notices: notices)
            totalBytes += result.dataURI.utf8.count
            guard totalBytes <= 40_000_000 else { throw ReaderError.message("多页图片总量过大，请查看原版。") }
            return result
        }
    }

    private static func pdfImages(_ data: Data) throws -> [PaperImage] {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
            !document.isEncrypted, document.numberOfPages > 0, document.numberOfPages <= 16
        else { throw ReaderError.message("PDF 图片无法完整读取，请查看原版。") }
        var totalBytes = 0
        return try (1...document.numberOfPages).map { index in
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw ReaderError.message("PDF 图片缺页。") }
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let width = rotated ? box.height : box.width
            let height = rotated ? box.width : box.height
            guard width > 0, height > 0, width.isFinite, height.isFinite else {
                throw ReaderError.message("PDF 图片尺寸无效。")
            }
            let scale = min(3, 4_096 / max(width, height))
            let pixelsWide = max(1, Int(ceil(width * scale)))
            let pixelsHigh = max(1, Int(ceil(height * scale)))
            guard
                let context = CGContext(
                    data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw ReaderError.message("无法准备 PDF 图片。") }
            let target = CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(target)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { throw ReaderError.message("PDF 图片绘制失败。") }
            let result = try png(image, notices: ["PDF 图件按高清静态图片呈现，全部页面按顺序保留。"])
            totalBytes += result.dataURI.utf8.count
            guard totalBytes <= 40_000_000 else { throw ReaderError.message("多页图片总量过大，请查看原版。") }
            return result
        }
    }

    private static func png(_ image: CGImage, notices: [String]) throws -> PaperImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ReaderError.message("无法创建兼容图片。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 24_000_000 else {
            throw ReaderError.message("图片转换失败或结果过大。")
        }
        return PaperImage(
            dataURI: "data:image/png;base64," + (data as Data).base64EncodedString(),
            width: Double(image.width), height: Double(image.height), notices: notices)
    }
}
