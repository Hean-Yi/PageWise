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
        var expectedToolChoice: String?
        var networkErrorCode: Int?

        init(
            statusCode: Int = 200, headers: [String: String] = [:], stream: Bool, chunks: [String],
            method: String? = nil, path: String? = nil, expectedToolChoice: String? = nil,
            networkErrorCode: Int? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.stream = stream
            self.chunks = chunks
            self.method = method
            self.path = path
            self.expectedToolChoice = expectedToolChoice
            self.networkErrorCode = networkErrorCode
        }

        static func sse(
            _ payloads: [String], statusCode: Int = 200, headers: [String: String] = [:],
            expectedToolChoice: String? = nil
        ) -> Entry {
            Entry(
                statusCode: statusCode, headers: headers, stream: true, chunks: payloads,
                expectedToolChoice: expectedToolChoice)
        }

        static func json(
            _ body: String, statusCode: Int = 200, headers: [String: String] = [:],
            expectedToolChoice: String? = nil
        ) -> Entry {
            Entry(
                statusCode: statusCode, headers: headers, stream: false, chunks: [body],
                expectedToolChoice: expectedToolChoice)
        }

        static func networkError(_ code: URLError.Code, stream: Bool = true) -> Entry {
            Entry(statusCode: 0, stream: stream, chunks: [], networkErrorCode: code.rawValue)
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
    private let chunkSplitBytes: Int?
    private var replayCursor = 0
    private(set) var recordedEntries: [HTTPCassette.Entry] = []
    private(set) var recordedBodies: [String] = []
    private(set) var recordedMessages: [[AgentMessage]] = []

    init(cassette: HTTPCassette, chunkSplitBytes: Int? = nil) {
        mode = .replay(cassette.entries)
        self.chunkSplitBytes = chunkSplitBytes
    }

    init(cassetteURL: URL, chunkSplitBytes: Int? = nil) throws {
        let data = try Data(contentsOf: cassetteURL)
        let cassette = try JSONDecoder().decode(HTTPCassette.self, from: data)
        mode = .replay(cassette.entries)
        self.chunkSplitBytes = chunkSplitBytes
    }

    init(recording upstream: any HTTPTransport) {
        mode = .record(upstream)
        self.chunkSplitBytes = nil
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
            try Self.verifyRequestMatches(request, entry: entry)
            if let code = entry.networkErrorCode {
                throw URLError(URLError.Code(rawValue: code))
            }
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
            try Self.verifyRequestMatches(request, entry: entry)
            if let code = entry.networkErrorCode {
                throw URLError(URLError.Code(rawValue: code))
            }
            if let split = chunkSplitBytes, split > 0 {
                let bytes = Data(entry.chunks.joined().utf8)
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + split, bytes.count)
                    try await onData(bytes[offset..<end])
                    offset = end
                }
            } else {
                for chunk in entry.chunks {
                    try await onData(Data(chunk.utf8))
                }
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

    private static func verifyRequestMatches(_ request: URLRequest, entry: HTTPCassette.Entry) throws {
        if let expectedPath = entry.path, request.url?.path != expectedPath {
            throw ReaderError.message("回放请求路径不匹配：期望 \(expectedPath)，实际 \(request.url?.path ?? "nil")。")
        }
        if let expectedToolChoice = entry.expectedToolChoice {
            let object = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let actual = object?["tool_choice"] as? String ?? "nil"
            guard actual == expectedToolChoice else {
                throw ReaderError.message("回放 tool_choice 不匹配：期望 \(expectedToolChoice)，实际 \(actual)。")
            }
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
    /// completed message prefix (including round 0 -> round 1) survives byte-for-byte into the
    /// subsequent round.
    static func verifyPrefixStability(_ requests: [[AgentMessage]]) -> Bool {
        guard requests.count >= 2 else { return true }
        let systems = requests.compactMap { $0.first(where: { $0.role == "system" })?.content }
        guard systems.count == requests.count, Set(systems).count == 1 else { return false }
        for index in 0..<(requests.count - 1) {
            let earlier = requests[index]
            let later = requests[index + 1]
            guard later.count >= earlier.count, Array(later.prefix(earlier.count)) == earlier else {
                return false
            }
        }
        return true
    }

    /// Verifies full KV Prompt Cache stability across raw HTTP JSON request bodies:
    /// 1) `system` and message prefixes survive byte-for-byte from round 0 onward;
    /// 2) serialized `tools` definitions stay 100% byte-for-byte identical across all tool-enabled rounds.
    static func verifyFullRequestPrefixStability(_ bodies: [String]) -> Bool {
        guard bodies.count >= 2 else { return true }
        var decodedMessages: [[AgentMessage]] = []
        var toolPayloads: [Data] = []
        struct MessageEnvelope: Decodable {
            let messages: [AgentMessage]
        }
        for body in bodies {
            let data = Data(body.utf8)
            guard let envelope = try? JSONDecoder().decode(MessageEnvelope.self, from: data),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            decodedMessages.append(envelope.messages)
            let toolChoice = object["tool_choice"] as? String
            if toolChoice != "none", let tools = object["tools"],
                let serialized = try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
            {
                toolPayloads.append(serialized)
            }
        }
        guard verifyPrefixStability(decodedMessages) else { return false }
        if toolPayloads.count >= 2, Set(toolPayloads).count != 1 {
            return false
        }
        return true
    }

    static func verifyNoSecretLeakage(_ cassette: HTTPCassette, secrets: [String]) throws -> Bool {
        let encoded = String(decoding: try JSONEncoder().encode(cassette), as: UTF8.self)
        return secrets.allSatisfy { !encoded.contains($0) }
    }
}
