import Foundation

/// Stable source text and page geometry for PDF selection, note anchoring and reader regression tests.
public enum AttentionFixture {
    public static func write(to url: URL) throws {
        guard let file = Bundle.module.url(forResource: "Understanding Attention", withExtension: "pdf") else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.copyItem(at: file, to: url)
    }
}
