import Foundation

/// App-authored diagnoses can be shown to the reader or returned to a model without forwarding server text.
public enum ArxivQueryError: LocalizedError, Sendable {
    case http(status: Int, retryAfter: Date?)
    case network(URLError.Code)
    case invalidResponse
    case invalidQuery

    public var canRefineQuery: Bool {
        switch self {
        case .invalidQuery, .http(400, _), .http(422, _): true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .http(let status, let retryAfter):
            let next =
                retryAfter.map { date in
                    let style = Date.FormatStyle(
                        date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated,
                        time: .standard, locale: Locale(identifier: "zh_CN"))
                    return "可在 \(date.formatted(style)) 后重试。"
                } ?? "请稍后重试。"
            switch status {
            case 400, 422: return "arXiv 无法处理此检索式（HTTP \(status)），请调整关键词。"
            case 429: return "arXiv 已限制请求频率（HTTP 429）。" + next
            case 408, 500...599: return "arXiv 检索服务暂时不可用（HTTP \(status)）。" + next
            default: return "arXiv 检索请求失败（HTTP \(status)）。"
            }
        case .network(let code):
            switch code {
            case .notConnectedToInternet, .dataNotAllowed: return "设备当前无法联网，请检查网络连接后再检索 arXiv。"
            case .timedOut: return "连接 arXiv 超时，请稍后重试。"
            case .networkConnectionLost: return "连接 arXiv 时网络中断，请稍后重试。"
            case .cannotFindHost, .dnsLookupFailed: return "无法解析 arXiv 的服务器地址，请检查网络或 DNS 设置。"
            case .cannotConnectToHost: return "无法连接到 arXiv 服务器，请稍后重试。"
            default: return "连接 arXiv 失败（网络错误 \(code.rawValue)）。"
            }
        case .invalidResponse: return "arXiv 的响应格式异常，无法读取检索结果。"
        case .invalidQuery: return "arXiv 无法处理此检索式，请调整关键词。"
        }
    }
}

/// arXiv's legacy metadata API allows one connection and one request every three seconds across clients.
actor ArxivMetadataRequests {
    static let shared = ArxivMetadataRequests()
    private struct CacheEntry {
        let results: [PaperCandidate]
        let limit: Int
        let expires: ContinuousClock.Instant
    }

    private let spacing: Duration
    private let cacheLifetime: Duration
    private var cache: [String: CacheEntry] = [:]
    private let maxAutomaticWait: TimeInterval
    private let throttleDelay: TimeInterval
    private var earliestStart = ContinuousClock.now
    private var cooldown: (until: Date, status: Int)?
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(
        spacing: Duration = .seconds(3), maxAutomaticWait: TimeInterval = 15, throttleDelay: TimeInterval = 30,
        cacheLifetime: Duration = .seconds(600)
    ) {
        self.spacing = spacing
        self.maxAutomaticWait = maxAutomaticWait
        self.throttleDelay = throttleDelay
        self.cacheLifetime = cacheLifetime
    }

    func results(for url: URL, using transport: any HTTPTransport, searchKey: String?, limit: Int) async throws
        -> [PaperCandidate]
    {
        try Task.checkCancellation()
        if let cached = cachedResults(for: searchKey, limit: limit) { return cached }
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        // A preceding caller may have filled this entry while this request was queued.
        if let cached = cachedResults(for: searchKey, limit: limit) { return cached }

        let data = try await data(for: url, using: transport)
        let results = try ArxivClient.parseMetadata(data)
        try Task.checkCancellation()
        guard let searchKey else { return results }
        let selected = Array(results.prefix(limit))
        if !selected.isEmpty {
            if cache[searchKey] == nil, cache.count >= 32,
                let oldest = cache.min(by: { $0.value.expires < $1.value.expires })
            {
                cache.removeValue(forKey: oldest.key)
            }
            cache[searchKey] = CacheEntry(results: selected, limit: limit, expires: .now + cacheLifetime)
        }
        return selected
    }

    private func cachedResults(for key: String?, limit: Int) -> [PaperCandidate]? {
        guard let key, let entry = cache[key], entry.expires > .now, entry.limit >= limit else { return nil }
        return Array(entry.results.prefix(limit))
    }

    private func data(for url: URL, using transport: any HTTPTransport) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        var waitedForThrottle = false
        var allowedWait = maxAutomaticWait
        for attempt in 1...3 {
            try await waitForSlot(maxWait: allowedWait)
            allowedWait = maxAutomaticWait
            do {
                defer { earliestStart = .now + spacing }
                let (data, response) = try await transport.data(for: request)
                try Task.checkCancellation()
                guard response.url == url else { throw ArxivQueryError.invalidResponse }
                let status = response.statusCode
                if status == 200 {
                    guard data.count <= 2_000_000 else { throw ArxivQueryError.invalidResponse }
                    return data
                }

                let transient = [408, 429, 500, 502, 503, 504].contains(status)
                // arXiv may reply 429 without Retry-After. Back off across all callers in that case too.
                var retryAfter = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"))
                if status == 429, retryAfter == nil {
                    let until = Date().addingTimeInterval(throttleDelay * (waitedForThrottle ? 2 : 1))
                    cooldown = (until, status)
                    guard !waitedForThrottle else { throw ArxivQueryError.http(status: status, retryAfter: until) }
                    waitedForThrottle = true
                    allowedWait = max(allowedWait, throttleDelay)
                    retryAfter = until
                } else if transient, let until = retryAfter {
                    cooldown = (until, status)
                }
                guard transient, attempt < 3 else { throw ArxivQueryError.http(status: status, retryAfter: retryAfter) }
            } catch let error as URLError {
                try Task.checkCancellation()
                if error.code == .cancelled { throw CancellationError() }
                guard [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code),
                    attempt < 3
                else { throw ArxivQueryError.network(error.code) }
            }
            earliestStart = .now + spacing * attempt
        }
        throw ArxivQueryError.invalidResponse
    }

    private func waitForSlot(maxWait: TimeInterval) async throws {
        try Task.checkCancellation()
        if let cooldown {
            let remaining = cooldown.until.timeIntervalSinceNow
            guard remaining <= maxWait else {
                throw ArxivQueryError.http(status: cooldown.status, retryAfter: cooldown.until)
            }
            if remaining > 0 { earliestStart = max(earliestStart, .now + .seconds(remaining)) }
        }
        try await ContinuousClock().sleep(until: earliestStart)
        try Task.checkCancellation()
        self.cooldown = nil
    }

    static func retryDate(_ header: String?, now: Date = Date()) -> Date? {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Double(value) {
            return now.addingTimeInterval(min(seconds, max(0, Date.distantFuture.timeIntervalSince(now))))
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        return format.date(from: value)
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
