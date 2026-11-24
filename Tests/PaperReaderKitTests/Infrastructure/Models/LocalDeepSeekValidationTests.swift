#if DEBUG && os(macOS)
    import Foundation
    import PaperReaderKit
    import Testing

    @Test func debugValidationKeyRequiresExplicitLibraryOptInAndTheOfficialProvider() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("DEEPSEEK_API_KEY=fixture-only\n".utf8).write(to: root.appendingPathComponent(".env"))
        #expect(PDFTranslationValidationConfiguration.load(root: root) == nil)
        try Data().write(to: root.appendingPathComponent(".enable-deepseek-validation"))
        let config = try #require(PDFTranslationValidationConfiguration.load(root: root))
        #expect(config.key(for: config.settings) == "fixture-only")
        var other = config.settings
        other.baseURL = "https://example.org/v1"
        #expect(config.key(for: other) == nil)
    }
#endif
