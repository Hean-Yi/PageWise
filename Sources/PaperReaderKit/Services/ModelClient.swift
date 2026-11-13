import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
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
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReaderError.message("服务器返回了无效响应。") }
        return (data, http)
    }
}

public struct ModelClient: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }

    public func complete(settings: ModelSettings, key: String, system: String, user: String) async throws -> String {
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
            temperature: settings.temperature)
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
        let stream = false
        let maxTokens = 4096
        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
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
