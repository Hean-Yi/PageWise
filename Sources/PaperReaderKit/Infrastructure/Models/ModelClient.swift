import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func downloadFile(for request: URLRequest, maximumBytes: Int64) async throws -> (URL, HTTPURLResponse)
    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws -> HTTPURLResponse
}

extension HTTPTransport {
    public func downloadFile(for request: URLRequest, maximumBytes: Int64) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard data.count <= maximumBytes else { throw ReaderError.message("全文超出下载大小限制。") }
        try Task.checkCancellation()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: target, options: .withoutOverwriting)
        return (target, response)
    }

    public func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws
        -> HTTPURLResponse
    {
        let (data, response) = try await data(for: request)
        if (200...299).contains(response.statusCode) { try await onData(data) }
        return response
    }
}

private final class NoRedirects: NSObject, URLSessionDownloadDelegate {
    let maximumBytes: Int64?
    init(maximumBytes: Int64? = nil) { self.maximumBytes = maximumBytes }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if let maximumBytes, max(totalBytesWritten, totalBytesExpectedToWrite) > maximumBytes {
            downloadTask.cancel()
        }
    }

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
    public func downloadFile(for request: URLRequest, maximumBytes: Int64) async throws -> (URL, HTTPURLResponse) {
        let (file, response) = try await session.download(
            for: request, delegate: NoRedirects(maximumBytes: maximumBytes))
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ReaderError.message("服务器返回了无效响应。") }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= maximumBytes else { throw ReaderError.message("全文超出下载大小限制。") }
            return (file, http)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
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

    public func complete(
        settings: ModelSettings, key: String, system: String, user: String, jsonOutput: Bool = false,
        maxOutputTokens: Int = 4096
    )
        async throws -> String
    {
        let request = try ChatCompletionRequest.make(
            settings: settings, key: key,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            maxOutputTokens: maxOutputTokens, jsonOutput: jsonOutput)
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
        if decoded.choices.first?.finishReason == "length" { throw TruncatedCompletion() }
        guard let choice = decoded.choices.first, choice.finishReason == "stop",
            let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else {
            throw ReaderError.message("模型未返回完整文本，结果未保存；可调整模型或重试。")
        }
        return text
    }

    struct TruncatedCompletion: LocalizedError {
        var errorDescription: String? { "模型未返回完整文本，结果未保存；可调整模型或重试。" }
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
