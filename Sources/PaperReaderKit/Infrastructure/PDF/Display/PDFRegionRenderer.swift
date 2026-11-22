import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PDFRegionRenderer {
    /// Bounds use the original, unrotated PDF page coordinates, just like PDFKit selection bounds.
    /// A partially visible or invalid region must be checked on the original page.
    static func png(page: PDFPage, bounds: CGRect) -> Data? {
        guard let reference = page.pageRef, page.rotation.isMultiple(of: 90),
            !bounds.isNull, !bounds.isInfinite, bounds.size.width > 0, bounds.size.height > 0,
            page.bounds(for: .cropBox).contains(bounds)
        else { return nil }

        let pageToDisplay = page.transform(for: .cropBox)
        let displayed = bounds.applying(pageToDisplay)
        let area = displayed.width * displayed.height
        guard displayed.minX.isFinite, displayed.minY.isFinite, displayed.width > 0, displayed.height > 0,
            area.isFinite, area > 0
        else { return nil }

        // Keep fine vector strokes legible while limiting each transient RGB bitmap to 8 MiB.
        let scale = min(4, 2048 / max(displayed.width, displayed.height), sqrt(2_097_152 / area))
        let width = max(1, Int((displayed.width * scale).rounded(.down)))
        let height = max(1, Int((displayed.height * scale).rounded(.down)))
        guard
            let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.interpolationQuality = .high
        bitmap.scaleBy(x: CGFloat(width) / displayed.width, y: CGFloat(height) / displayed.height)
        bitmap.translateBy(x: -displayed.minX, y: -displayed.minY)
        bitmap.concatenate(pageToDisplay)
        bitmap.drawPDFPage(reference)

        let data = NSMutableData()
        guard let image = bitmap.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
