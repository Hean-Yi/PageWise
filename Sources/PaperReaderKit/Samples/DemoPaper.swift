import Foundation

/// Original two-page teaching note. Its stable PDF bytes allow re-opening the same annotated copy.
public enum DemoPaper {
    public static func fileURL() throws -> URL {
        guard
            let url = Bundle.module.url(
                forResource: "Understanding Attention", withExtension: "pdf", subdirectory: "Samples")
        else { throw ReaderError.message("无法打开随应用提供的示例论文。") }
        return url
    }

    public static func write(to url: URL) throws {
        try FileManager.default.copyItem(at: fileURL(), to: url)
    }
}
