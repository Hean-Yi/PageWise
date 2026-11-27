import Foundation

public struct ModelSettings: Codable, Equatable, Sendable {
    public static let glmBaseURL = "https://open.bigmodel.cn/api/paas/v4"
    public var baseURL = Self.glmBaseURL
    public var model = ""
    public var temperature = 0.2
    /// A Keychain account identifier, never the API key itself. Nil supports the original MVP account.
    public var credentialID: String?
    /// Non-sensitive hint recorded on save so UI readiness checks avoid triggering Keychain prompts at launch.
    public var hasStoredCredential: Bool?
    public init() {}

    public func endpointURL() throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value), components.scheme?.lowercased() == "https",
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            !value.contains(where: { $0.isWhitespace })
        else {
            throw ReaderError.message("请输入有效的 HTTPS API 地址，不要包含密钥、查询参数或账号信息。")
        }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        if let port = components.port, !(1...65535).contains(port) {
            throw ReaderError.message("API 地址的端口无效。")
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        if !components.path.hasSuffix("/chat/completions") { components.path += "/chat/completions" }
        guard let url = components.url else { throw ReaderError.message("API 地址无效。") }
        return url
    }

    public func normalized() throws -> ModelSettings {
        var result = self
        let endpoint = try endpointURL()
        result.baseURL = String(endpoint.absoluteString.dropLast("/chat/completions".count))
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.model.isEmpty, !result.model.contains(where: { $0.isNewline }) else {
            throw ReaderError.message("请填写该账户可用的模型名称。")
        }
        guard temperature.isFinite, (0...2).contains(temperature) else {
            throw ReaderError.message("模型温度必须在 0 到 2 之间。")
        }
        return result
    }
}
