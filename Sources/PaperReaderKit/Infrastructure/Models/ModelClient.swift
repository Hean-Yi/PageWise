import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
}

extension HTTPTransport {
    public func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws
        -> HTTPURLResponse
    {
        let (data, response) = try await data(for: request)
        if (200...299).contains(response.statusCode) { try await onData(data) }
        return response
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct NetworkTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReaderError.message("服务器返回了无效响应。") }
        return (data, http)
    }

    public func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws
        -> HTTPURLResponse
    {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReaderError.message("服务器返回了无效响应。") }
        guard (200...299).contains(http.statusCode) else { return http }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try await onData(Data((line + "\n").utf8))
        }
        return http
    }
}

public struct ModelClient: Sendable {
    let transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }

    public func complete(settings: ModelSettings, key: String, system: String, user: String, jsonOutput: Bool = false)
        async throws -> String
    {
        let settings = try settings.normalized()
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ReaderError.message("请先在设置中保存 API Key。")
        }
        guard !key.contains(where: { $0.isWhitespace }) else {
            throw ReaderError.message("API Key 中不能包含空格或换行。")
        }
        let endpoint = try settings.endpointURL()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body = RequestBody(
            model: settings.model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            temperature: settings.temperature,
            responseFormat: jsonOutput ? ["type": "json_object"] : nil,
            thinking: jsonOutput && endpoint.host == "api.deepseek.com" && settings.model == "deepseek-flash"
                ? ["type": "disabled"] : nil)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200...299: break
        case 401, 403: throw ReaderError.message("模型服务拒绝访问，请检查密钥、模型权限和 API 地址。")
        case 429: throw ReaderError.message("模型服务限流或额度不足，请稍后重试。已完成内容已保留。")
        default: throw ReaderError.message("模型请求失败（HTTP \(response.statusCode)）。未自动重试，以免重复计费。")
        }
        let decoded: ResponseBody
        do { decoded = try JSONDecoder().decode(ResponseBody.self, from: data) } catch {
            throw ReaderError.message("模型响应格式不兼容，请检查服务设置。")
        }
        guard let choice = decoded.choices.first, choice.finishReason == "stop",
            let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else {
            throw ReaderError.message("模型未返回完整文本，结果未保存；可调整模型或重试。")
        }
        return text
    }

    private struct RequestBody: Encodable {
        var model: String
        var messages: [Message]
        var temperature: Double
        var responseFormat: [String: String]?
        var thinking: [String: String]?
        var stream = false
        let maxTokens = 4096
        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream, thinking
            case maxTokens = "max_tokens"
            case responseFormat = "response_format"
        }
    }
    private struct Message: Codable {
        var role: String
        var content: String
    }
    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Content: Decodable { var content: String? }
            var message: Content
            var finishReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        var choices: [Choice]
    }
}
