import SwiftUI
import Testing

@testable import PaperReaderUI

@Test func shelfLabelsWrapInOrderAndRejoinWhenMoreWidthBecomesAvailable() {
    let layout = ShelfRows()
    let sizes = [70, 86, 340, 36].map { CGSize(width: CGFloat($0), height: 36) }
    func frames(at width: CGFloat) -> [CGRect] {
        var frames = [CGRect]()
        let height = layout.arrange(sizes, width: width) { _, rect in frames.append(rect) }
        #expect(height == frames.last?.maxY)
        return frames
    }
    let narrow = frames(at: 160)
    #expect(narrow[0].minY == narrow[1].minY && narrow[1].maxX == 160)
    #expect(narrow[2].minY > narrow[1].maxY && narrow[2].minX == 0 && narrow[2].width == 160)
    #expect(narrow[3].minY > narrow[2].maxY && narrow[3].minX == 0)
    #expect(frames(at: 600).allSatisfy { $0.minY == 0 })
}
