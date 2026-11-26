import Foundation
import PaperReaderKit

/// Serializable HTTP fixture for deterministic offline record/replay of Agent and Model sessions.
/// Credentials and authorization headers are never written to a cassette.
struct HTTPCassette: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var statusCode: Int
        var headers: [String: String]
        var stream: Bool
        var chunks: [String]
        var method: String?
        var path: String?

        init(
            statusCode: Int = 200, headers: [String: String] = [:], stream: Bool, chunks: [String],
            method: String? = nil, path: String? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.stream = stream
            self.chunks = chunks
            self.method = method
            self.path = path
        }

        static func sse(_ payloads: [String], statusCode: Int = 200) -> Entry {
            Entry(statusCode: statusCode, stream: true, chunks: payloads)
        }

        static func json(_ body: String, statusCode: Int = 200) -> Entry {
            Entry(statusCode: statusCode, stream: false, chunks: [body])
        }
    }

    var entries: [Entry]

    init(entries: [Entry] = []) {
        self.entries = entries
    }
}

/// Deterministic HTTPTransport supporting both offline replay and redacted live/mock recording.
actor CassetteTransport: HTTPTransport {
    enum Mode {
        case replay([HTTPCassette.Entry])
        case record(any HTTPTransport)
    }

    private let mode: Mode
    private var replayCursor = 0
    private(set) var recordedEntries: [HTTPCassette.Entry] = []
    private(set) var recordedBodies: [String] = []
    private(set) var recordedMessages: [[AgentMessage]] = []

    init(cassette: HTTPCassette) {
        mode = .replay(cassette.entries)
    }

    init(cassetteURL: URL) throws {
        let data = try Data(contentsOf: cassetteURL)
        let cassette = try JSONDecoder().decode(HTTPCassette.self, from: data)
        mode = .replay(cassette.entries)
    }

    init(recording upstream: any HTTPTransport) {
        mode = .record(upstream)
    }

    func cassette() -> HTTPCassette {
        HTTPCassette(entries: recordedEntries)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cassette())
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captureRequest(request)
        switch mode {
        case .replay(let entries):
            guard replayCursor < entries.count else {
                throw ReaderError.message("回放夹具已耗尽（data）。")
            }
            let entry = entries[replayCursor]
            replayCursor += 1
            let body = entry.chunks.joined()
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://cassette.invalid")!,
                statusCode: entry.statusCode, httpVersion: nil, headerFields: entry.headers)!
            return (Data(body.utf8), response)
        case .record(let upstream):
            let (data, response) = try await upstream.data(for: request)
            recordedEntries.append(
                HTTPCassette.Entry(
                    statusCode: response.statusCode,
                    headers: Self.redactedHeaders(response.allHeaderFields),
                    stream: false,
                    chunks: [String(decoding: data, as: UTF8.self)],
                    method: request.httpMethod,
                    path: request.url?.path))
            return (data, response)
        }
    }

    func stream(for request: URLRequest, onData: @Sendable (Data) async throws -> Void) async throws
        -> HTTPURLResponse
    {
        captureRequest(request)
        switch mode {
        case .replay(let entries):
            guard replayCursor < entries.count else {
                throw ReaderError.message("回放夹具已耗尽（stream）。")
            }
            let entry = entries[replayCursor]
            replayCursor += 1
            for chunk in entry.chunks {
                try await onData(Data(chunk.utf8))
            }
            return HTTPURLResponse(
                url: request.url ?? URL(string: "https://cassette.invalid")!,
                statusCode: entry.statusCode, httpVersion: nil, headerFields: entry.headers)!
        case .record(let upstream):
            let collector = ChunkCollector()
            let response = try await upstream.stream(for: request) { data in
                await collector.append(String(decoding: data, as: UTF8.self))
                try await onData(data)
            }
            recordedEntries.append(
                HTTPCassette.Entry(
                    statusCode: response.statusCode,
                    headers: Self.redactedHeaders(response.allHeaderFields),
                    stream: true,
                    chunks: await collector.chunks,
                    method: request.httpMethod,
                    path: request.url?.path))
            return response
        }
    }

    private func captureRequest(_ request: URLRequest) {
        guard let body = request.httpBody else { return }
        recordedBodies.append(String(decoding: body, as: UTF8.self))
        struct Envelope: Decodable {
            let messages: [AgentMessage]?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
            let messages = envelope.messages
        {
            recordedMessages.append(messages)
        }
    }

    private static func redactedHeaders(_ raw: [AnyHashable: Any]) -> [String: String] {
        var clean: [String: String] = [:]
        let sensitive: Set<String> = ["authorization", "set-cookie", "x-api-key", "api-key"]
        for (key, value) in raw {
            let name = String(describing: key)
            guard !sensitive.contains(name.lowercased()) else { continue }
            clean[name] = String(describing: value)
        }
        return clean
    }

    private actor ChunkCollector {
        var chunks: [String] = []
        func append(_ chunk: String) { chunks.append(chunk) }
    }
}

/// Deterministic trajectory assertions modeled after agent evaluation harnesses.
enum TrajectoryAssertion {
    static func succeededToolNames(in turn: AgentTurn) -> [String] {
        turn.activities.filter { $0.status == .succeeded }.map(\.toolName)
    }

    static func verifyExactTools(_ turn: AgentTurn, expected: [String]) -> Bool {
        turn.activities.map(\.toolName) == expected
    }

    static func verifyToolSubset(_ turn: AgentTurn, required: Set<String>) -> Bool {
        required.isSubset(of: Set(succeededToolNames(in: turn)))
    }

    static func verifyNoForbiddenSucceededTools(_ turn: AgentTurn, forbidden: Set<String>) -> Bool {
        Set(succeededToolNames(in: turn)).isDisjoint(with: forbidden)
    }

    /// Asserts that `messages[0]` (system) never changes across rounds, and every round's
    /// completed message prefix survives byte-for-byte into the subsequent round.
    static func verifyPrefixStability(_ requests: [[AgentMessage]]) -> Bool {
        guard requests.count >= 2 else { return true }
        let systems = requests.compactMap { $0.first(where: { $0.role == "system" })?.content }
        guard Set(systems).count == 1 else { return false }
        for index in 1..<(requests.count - 1) {
            let earlier = requests[index]
            let later = requests[index + 1]
            guard later.count >= earlier.count, Array(later.prefix(earlier.count)) == earlier else {
                return false
            }
        }
        return true
    }

    static func verifyNoSecretLeakage(_ cassette: HTTPCassette, secrets: [String]) throws -> Bool {
        let encoded = String(decoding: try JSONEncoder().encode(cassette), as: UTF8.self)
        return secrets.allSatisfy { !encoded.contains($0) }
    }
}
