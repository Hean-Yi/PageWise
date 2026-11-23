import Foundation

/// App-authored diagnoses can be shown to the reader or returned to a model without forwarding server text.
public enum ArxivQueryError: LocalizedError, Sendable {
    case http(status: Int, retryAfter: Date?)
    case cooldown(status: Int, until: Date)
    indirect case incompleteSearch(arxiv: ArxivQueryError, doiReturnedNoMatches: Bool)
    case network(URLError.Code)
    case invalidResponse
    case invalidQuery

    public var offersWebSearch: Bool {
        switch self {
        case .http(429, _), .http(500...599, _), .cooldown: true
        case .incompleteSearch(let arxiv, _): arxiv.offersWebSearch
        default: false
        }
    }

    var allowsMetadataFallback: Bool {
        switch self {
        case .http(429, _), .http(408, _), .http(500...599, _), .cooldown, .invalidResponse: true
        case .network(let code):
            [.timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost].contains(code)
        default: false
        }
    }

    public var canRefineQuery: Bool {
        switch self {
        case .invalidQuery, .http(400, _), .http(422, _): true
        case .incompleteSearch(let arxiv, let empty): empty || arxiv.canRefineQuery
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .incompleteSearch(let arxiv, let empty):
            return (empty ? "DataCite 的 arXiv 题名索引未命中。" : "DataCite 的 arXiv 题名索引暂时不可用。") + arxiv.localizedDescription
        case .cooldown(let status, let until):
            return "上次 arXiv 请求返回 HTTP \(status)，本次仍在等待，未向 arXiv API 再发请求。" + Self.retryHint(until)
        case .http(let status, let retryAfter):
            let next = retryAfter.map(Self.retryHint) ?? "请稍后重试。"
            switch status {
            case 400, 422: return "arXiv 无法处理此检索式（HTTP \(status)），请调整关键词。"
            case 429:
                return "arXiv 已限制请求频率（HTTP 429）。"
                    + (retryAfter.map(Self.retryHint) ?? "服务端未提供重试时间，应用会短暂等待。")
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

    private static func retryHint(_ date: Date) -> String {
        let style = Date.FormatStyle(
            date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated,
            time: .standard, locale: Locale(identifier: "zh_CN"))
        return "可在 \(date.formatted(style)) 后重试。"
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
    private var doiRetryAt: Date?
    private enum Queue: Hashable {
        case search(String)
        case doi, atom
    }
    private typealias Waiter = (id: UUID, continuation: CheckedContinuation<Void, any Error>)
    // An entry exists while its owner holds the queue, even when nobody is waiting.
    private var waiters: [Queue: [Waiter]] = [:]

    init(
        spacing: Duration = .seconds(3), maxAutomaticWait: TimeInterval = 15, throttleDelay: TimeInterval = 30,
        cacheLifetime: Duration = .seconds(600)
    ) {
        self.spacing = spacing
        self.maxAutomaticWait = maxAutomaticWait
        self.throttleDelay = throttleDelay
        self.cacheLifetime = cacheLifetime
    }

    func results(
        for url: URL, using transport: any HTTPTransport, searchKey: String?, limit: Int, doiQuery: String? = nil
    ) async throws
        -> [PaperCandidate]
    {
        try Task.checkCancellation()
        guard let searchKey else {
            let results = try await lookup(url, doiQuery: doiQuery, limit: limit, transport: transport)
            try Task.checkCancellation()
            return results
        }
        if let cached = cachedResults(for: searchKey, limit: limit) { return cached }
        try await acquire(.search(searchKey))
        defer { release(.search(searchKey)) }
        try Task.checkCancellation()
        // A preceding caller may have filled this entry while this request was queued.
        if let cached = cachedResults(for: searchKey, limit: limit) { return cached }

        let results = try await lookup(url, doiQuery: doiQuery, limit: limit, transport: transport)
        try Task.checkCancellation()
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

    private func lookup(_ url: URL, doiQuery: String?, limit: Int, transport: any HTTPTransport) async throws
        -> [PaperCandidate]
    {
        var doiReturnedNoMatches = false
        if let doiQuery {
            try await acquire(.doi)
            defer { release(.doi) }
            try Task.checkCancellation()
            if doiRetryAt.map({ $0 <= Date() }) ?? true {
                do {
                    let records = try await ArxivDOISearch.search(doiQuery, limit: limit, using: transport)
                    try Task.checkCancellation()
                    if !records.isEmpty { return records }
                    doiReturnedNoMatches = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch ArxivDOISearch.Failure.rateLimited(let until) {
                    doiRetryAt = until
                } catch {
                    try Task.checkCancellation()
                }
            }
        }
        do {
            return try ArxivClient.parseMetadata(await data(for: url, using: transport))
        } catch let error as ArxivQueryError where doiQuery != nil {
            throw ArxivQueryError.incompleteSearch(arxiv: error, doiReturnedNoMatches: doiReturnedNoMatches)
        }
    }

    private func cachedResults(for key: String, limit: Int) -> [PaperCandidate]? {
        guard let entry = cache[key], entry.expires > .now, entry.limit >= limit else { return nil }
        return Array(entry.results.prefix(limit))
    }

    private func data(for url: URL, using transport: any HTTPTransport) async throws -> Data {
        try await acquire(.atom)
        defer { release(.atom) }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        for attempt in 1...3 {
            try await waitForSlot(maxWait: maxAutomaticWait)
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
                let retryAfter = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"))
                if status == 429 {
                    let until = retryAfter ?? Date().addingTimeInterval(throttleDelay)
                    cooldown = (until, status)
                    throw ArxivQueryError.http(status: status, retryAfter: retryAfter)
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
            if remaining > 0 && (cooldown.status == 429 || remaining > maxWait) {
                throw ArxivQueryError.cooldown(status: cooldown.status, until: cooldown.until)
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

    private func acquire(_ queue: Queue) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if waiters[queue] == nil {
                    waiters[queue] = []
                    continuation.resume()
                } else {
                    waiters[queue]?.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, in: queue) }
        }
    }

    private func cancelWaiter(_ id: UUID, in queue: Queue) {
        guard let index = waiters[queue]?.firstIndex(where: { $0.id == id }) else { return }
        waiters[queue]?.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ queue: Queue) {
        if waiters[queue]?.isEmpty == false {
            waiters[queue]?.removeFirst().continuation.resume()
        } else {
            waiters.removeValue(forKey: queue)
        }
    }
}
