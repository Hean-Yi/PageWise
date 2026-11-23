import Foundation

/// An explicitly marked Mac acceptance build may use its isolated library's local credential for a live PDF test.
public struct PDFTranslationValidationConfiguration: Sendable {
    public let settings: ModelSettings
    let key: String

    public func key(for request: ModelSettings) -> String? {
        guard let endpoint = try? request.endpointURL(), endpoint == (try? settings.endpointURL()),
            request.model.trimmingCharacters(in: .whitespacesAndNewlines) == settings.model
        else { return nil }
        return key
    }

    public static func load(root: URL) -> Self? {
        #if DEBUG && os(macOS)
            guard Bundle.main.object(forInfoDictionaryKey: "PaperReaderPDFValidation") as? Bool == true,
                let content = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)
            else { return nil }
            let prefix = "DEEPSEEK_API_KEY="
            guard let line = content.components(separatedBy: .newlines).first(where: { $0.hasPrefix(prefix) }) else {
                return nil
            }
            let key = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
            var settings = ModelSettings()
            settings.baseURL = "https://api.deepseek.com"
            settings.model = "deepseek-flash"
            return Self(settings: settings, key: key)
        #else
            return nil
        #endif
    }
}
