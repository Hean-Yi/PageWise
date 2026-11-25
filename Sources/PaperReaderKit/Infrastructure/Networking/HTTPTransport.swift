import Foundation
import Synchronization

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

private class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// URLSession delivers every delegate call on its serial delegate queue. Keep the file and
/// byte counter there, and return ownership only after the task has stopped writing.
private final class FileDownload: NoRedirects, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let output: FileHandle
    private let finished: CheckedContinuation<HTTPURLResponse, any Error>
    private var received: Int64 = 0
    private var failure: (any Error)?

    init(maximumBytes: Int64, output: FileHandle, finished: CheckedContinuation<HTTPURLResponse, any Error>) {
        self.maximumBytes = maximumBytes
        self.output = output
        self.finished = finished
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if response.expectedContentLength > maximumBytes {
            failure = ReaderError.message("全文超出下载大小限制。")
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            guard Int64(data.count) <= maximumBytes - received else {
                throw ReaderError.message("全文超出下载大小限制。")
            }
            try output.write(contentsOf: data)
            received += Int64(data.count)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { session.finishTasksAndInvalidate() }
        if let error = failure ?? error {
            finished.resume(throwing: error)
        } else if let response = task.response as? HTTPURLResponse {
            finished.resume(returning: response)
        } else {
            finished.resume(throwing: ReaderError.message("服务器返回了无效响应。"))
        }
    }
}

public struct NetworkTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 300
        self.init(configuration: configuration)
    }
    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    public func downloadFile(for request: URLRequest, maximumBytes: Int64) async throws -> (URL, HTTPURLResponse) {
        try Task.checkCancellation()
        guard maximumBytes >= 0 else { throw ReaderError.message("全文超出下载大小限制。") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: target, options: .withoutOverwriting)
        do {
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            let active = Mutex<URLSessionDataTask?>(nil)
            let response: HTTPURLResponse = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let delegate = FileDownload(maximumBytes: maximumBytes, output: output, finished: continuation)
                    let downloadSession = URLSession(
                        configuration: session.configuration, delegate: delegate, delegateQueue: nil)
                    let task = downloadSession.dataTask(with: request)
                    active.withLock {
                        $0 = task
                        task.resume()
                        if Task.isCancelled { task.cancel() }
                    }
                }
            } onCancel: {
                active.withLock { $0?.cancel() }
            }
            try Task.checkCancellation()
            return (target, response)
        } catch {
            try? FileManager.default.removeItem(at: target)
            try Task.checkCancellation()
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
