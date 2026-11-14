import Foundation
import SwiftSoup

enum HTMLImageNormalizer {
    static func normalize(_ article: Element, source: URL, transport: any HTTPTransport) async throws {
        let markers = ["data-pr-image", "data-pr-notice", "data-pr-failure", "data-pr-coverage"]
        for element in try article.select("*") {
            for marker in markers { try element.removeAttr(marker) }
        }
        let loader = PaperImageLoader(source: source, transport: transport)
        let elements = try article.select("img,svg,object,embed").filter { element in
            !element.parents().contains { ["svg", "object", "embed"].contains($0.tagName()) }
        }
        var embeddedBytes = 0
        for (index, element) in elements.enumerated() {
            try Task.checkCancellation()
            let wrapper = try Element(Tag.valueOf("div"), "").attr("data-pr-image", "true")
            do {
                guard index < 150 else { throw ReaderError.message("图片数量超出本地处理范围。") }
                let images: [PaperImage]
                if element.tagName() == "svg" {
                    images = try await loader.inlineSVG(element.outerHtml())
                } else {
                    let reference = try element.attr(element.tagName() == "object" ? "data" : "src")
                    images = try await loader.load(reference)
                }
                let size = images.reduce(0) { $0 + $1.dataURI.utf8.count }
                guard size + embeddedBytes <= 80_000_000 else { throw ReaderError.message("图片总量超出本地处理范围。") }
                embeddedBytes += size
                try wrapper.attr("data-pr-coverage", images.map(\.coverageText).joined(separator: " "))
                for image in images {
                    let node = try Element(Tag.valueOf("img"), "")
                        .attr("src", image.dataURI).attr("width", String(image.width)).attr(
                            "height", String(image.height)
                        )
                        .attr("alt", element.attr("alt"))
                    try wrapper.appendChild(node)
                }
                for notice in Set(images.flatMap(\.notices)).sorted() { try appendNotice(notice, to: wrapper) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                try appendNotice("图片未能转换，请查看原版。" + error.localizedDescription, to: wrapper, failed: true)
            }
            try element.replaceWith(wrapper)
        }
    }

    private static func appendNotice(_ text: String, to wrapper: Element, failed: Bool = false) throws {
        let node = try Element(Tag.valueOf("div"), "").attr("data-pr-notice", "true").text(text)
        if failed { try node.attr("data-pr-failure", "true") }
        try wrapper.appendChild(node)
    }
}
