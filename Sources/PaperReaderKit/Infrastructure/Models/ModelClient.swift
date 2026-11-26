import Foundation

public struct ModelClient: Sendable {
    let transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }

    public func agentClient() -> AgentClient { AgentClient(transport: transport) }

    public func complete(
        settings: ModelSettings, key: String, system: String, user: String, jsonOutput: Bool = false,
        maxOutputTokens: Int = 4096, maxTransientRetries: Int = 2
    )
        async throws -> String
    {
        let request = try ChatCompletionRequest.make(
            settings: settings, key: key,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            maxOutputTokens: maxOutputTokens, jsonOutput: jsonOutput)
        let maxRetries = max(0, min(3, maxTransientRetries))
        var attempt = 0
        while true {
            do {
                return try await completeOnce(request: request, jsonOutput: jsonOutput)
            } catch let retry as RetrySignal {
                attempt += 1
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(retry.delayMilliseconds))
            }
        }
    }

    private struct RetrySignal: Error {
        let delayMilliseconds: Int
    }

    private func completeOnce(request: URLRequest, jsonOutput: Bool) async throws -> String {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let urlError as URLError {
            try Task.checkCancellation()
            if Self.isTransientNetworkError(urlError) {
                throw RetrySignal(delayMilliseconds: 300)
            }
            throw ReaderError.message("模型网络请求未完成，请检查连接后重试。")
        }
        switch response.statusCode {
        case 200...299: break
        case 401, 403: throw ReaderError.message("模型服务拒绝访问，请检查密钥、模型权限和 API 地址。")
        case 408, 425, 429:
            if let delay = Self.retryAfterMilliseconds(response, fallback: 500) {
                throw RetrySignal(delayMilliseconds: delay)
            }
            throw ReaderError.message("模型服务限流或额度不足，请稍后重试。已完成内容已保留。")
        case 500...599:
            if let delay = Self.retryAfterMilliseconds(response, fallback: 400) {
                throw RetrySignal(delayMilliseconds: delay)
            }
            throw ReaderError.message("模型请求失败（HTTP \(response.statusCode)）；重试后仍未恢复。")
        default: throw ReaderError.message("模型请求失败（HTTP \(response.statusCode)）。未自动重试。")
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw ReaderError.message("模型响应超过长度上限，结果未保存。")
        }
        let decoded: ResponseBody
        do { decoded = try JSONDecoder().decode(ResponseBody.self, from: data) } catch {
            throw ReaderError.message("模型响应格式不兼容，请检查服务设置。")
        }
        if decoded.choices.first?.finishReason == "length" { throw TruncatedCompletion() }
        guard let choice = decoded.choices.first, choice.finishReason == "stop",
            let raw = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else {
            throw ReaderError.message("模型未返回完整文本，结果未保存；可调整模型或重试。")
        }
        guard jsonOutput else { return raw }
        // Fences and reasoning tags are stripped when present. Callers still validate their own
        // schema; returning the raw text preserves the previous diagnostic path for plain replies.
        return ModelJSON.extractObject(from: raw) ?? raw
    }

    static let maximumResponseBytes = 2_000_000

    private static func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private static func retryAfterMilliseconds(_ response: HTTPURLResponse, fallback: Int) -> Int? {
        guard
            let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            let seconds = Double(raw)
        else { return fallback }
        guard seconds <= 10 else { return nil }
        return max(100, Int((seconds * 1000).rounded()))
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

/// Extracts the first complete JSON object from an untrusted model reply. Models routinely wrap
/// JSON in reasoning tags or Markdown fences even when `response_format` is requested.
enum ModelJSON {
    static func extractObject(from raw: String) -> String? {
        var source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenced = fencedObject(in: source) { source = fenced }
        let reasoningBlock =
            #"(?is)<(?:think|thought|thinking)\b[^>]*>.*?</(?:think|thought|thinking)\s*>"#
        source = source.replacingOccurrences(of: reasoningBlock, with: "", options: .regularExpression)
        if let close = source.range(
            of: #"</(?:think|thought|thinking)\s*>"#, options: [.regularExpression, .caseInsensitive])
        {
            source = String(source[close.upperBound...])
        } else if let open = source.range(
            of: #"<(?:think|thought|thinking)\b[^>]*>"#, options: [.regularExpression, .caseInsensitive])
        {
            let tail = String(source[open.upperBound...])
            if tail.contains("{") { source = tail }
        }
        guard let start = source.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[start...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func fencedObject(in text: String) -> String? {
        for fence in text.matches(of: /```(?:json|JSON)?\s*\n?(.*?)```/) {
            let body = String(fence.output.1)
            if body.contains("{"), extractObjectBody(body) != nil {
                return body
            }
        }
        return nil
    }

    private static func extractObjectBody(_ body: String) -> String? {
        guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}") else { return nil }
        return String(body[start...end])
    }
}
