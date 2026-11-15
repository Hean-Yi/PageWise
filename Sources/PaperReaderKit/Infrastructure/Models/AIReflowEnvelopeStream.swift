import Foundation

/// Incrementally frames the native JSON-mode object without waiting for the entire
/// response. Its event objects still pass through the complete v1 evidence validator.
actor AIReflowEnvelopeStream {
    private enum State {
        case objectStart, keyStart, key, colon, arrayStart, firstEvent, nextEvent
        case event, separator, objectEnd, finished
    }

    private let stream: AIReflowStream
    private var previous = Data()
    private var state = State.objectStart
    private var key = Data()
    private var event = Data()
    private var inString = false
    private var escaped = false
    private var objectDepth = 0

    init(stream: AIReflowStream) { self.stream = stream }

    func consume(_ output: String) async throws {
        let bytes = Data(output.utf8)
        guard bytes.count <= 2_000_000, bytes.starts(with: previous) else { throw AIReflowFailure.invalidStructure }
        let suffix = bytes.dropFirst(previous.count)
        previous = bytes
        for byte in suffix {
            switch state {
            case .objectStart:
                if Self.whitespace(byte) { continue }
                guard byte == 123 else { throw AIReflowFailure.invalidStructure }
                state = .keyStart
            case .keyStart:
                if Self.whitespace(byte) { continue }
                guard byte == 34 else { throw AIReflowFailure.invalidStructure }
                key = Data([byte])
                escaped = false
                state = .key
            case .key:
                key.append(byte)
                guard key.count <= 64 else { throw AIReflowFailure.invalidStructure }
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    guard (try? JSONDecoder().decode(String.self, from: key)) == "events" else {
                        throw AIReflowFailure.invalidStructure
                    }
                    state = .colon
                }
            case .colon:
                if Self.whitespace(byte) { continue }
                guard byte == 58 else { throw AIReflowFailure.invalidStructure }
                state = .arrayStart
            case .arrayStart:
                if Self.whitespace(byte) { continue }
                guard byte == 91 else { throw AIReflowFailure.invalidStructure }
                state = .firstEvent
            case .firstEvent, .nextEvent:
                if Self.whitespace(byte) { continue }
                if byte == 93, state == .firstEvent {
                    state = .objectEnd
                    continue
                }
                guard byte == 123 else { throw AIReflowFailure.invalidStructure }
                event = Data([byte])
                objectDepth = 1
                inString = false
                escaped = false
                state = .event
            case .event:
                event.append(byte)
                guard event.count <= 65_536 else { throw AIReflowFailure.invalidStructure }
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 92 {
                        escaped = true
                    } else if byte == 34 {
                        inString = false
                    }
                } else if byte == 34 {
                    inString = true
                } else if byte == 123 {
                    objectDepth += 1
                    guard objectDepth <= 64 else { throw AIReflowFailure.invalidStructure }
                } else if byte == 125 {
                    objectDepth -= 1
                    if objectDepth == 0 {
                        state = .separator
                        // A validated block_end can commit here, before the array/object closes.
                        try await stream.consumeEvent(event)
                        event.removeAll(keepingCapacity: true)
                    }
                }
            case .separator:
                if Self.whitespace(byte) { continue }
                if byte == 44 {
                    state = .nextEvent
                } else if byte == 93 {
                    state = .objectEnd
                } else {
                    throw AIReflowFailure.invalidStructure
                }
            case .objectEnd:
                if Self.whitespace(byte) { continue }
                guard byte == 125 else { throw AIReflowFailure.invalidStructure }
                state = .finished
            case .finished:
                guard Self.whitespace(byte) else { throw AIReflowFailure.invalidStructure }
            }
        }
    }

    func finish() async throws {
        guard state == .finished else { throw AIReflowFailure.invalidStructure }
        try await stream.finish()
    }

    private static func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
}
