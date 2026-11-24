import Foundation

/// All Agent source pages are one-based; stored TextBlock pages remain zero-based.
public struct AgentCard: Identifiable, Sendable {
    public enum Kind: String, Sendable { case localPaper, evidence, onlineCandidate, navigation }
    public var id = UUID()
    public var kind: Kind
    public var title: String
    /// Query that produced this result, scoped to this card's occurrence in the conversation.
    public var searchQuery: String?
    public var subtitle = ""
    public var authors: String? = nil
    public var year: String? = nil
    public var excerpt = ""
    public var sourcePage: Int?
    public var paperID: UUID?
    public var blockID: UUID?
    public var readingNoteID: UUID?
    public var noteModifiedAt: Date?
    public var candidateID: String?
    public var sourceURL: URL?
    public var sourceName: String?
    public var alternateVersionIDs: [UUID] = []
    public var hasDownload = false
    public var canLookUpFullText = false
    public var canAttemptDownload: Bool { hasDownload || canLookUpFullText }
    public var importState: AgentImportState = .unprepared
    public enum Removal: Sendable, Equatable {
        case paper(UUID)
        case shelf(UUID, members: Set<UUID>)
    }
    public enum ImportDestination: Sendable, Equatable {
        case unfiled
        case shelf(UUID)
    }
    public var localImportDestination: ImportDestination?
    public var removal: Removal?
    public var removalGeneration: Date?
    public var removalCompleted = false
    public var importError: String?
    public var canImport: Bool {
        canAttemptDownload && candidateID != nil && [.unprepared, .ready, .failed, .cancelled].contains(importState)
    }
    public var canOpen: Bool { paperID != nil }
    public init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }
}

public enum AgentImportState: String, Sendable {
    case unprepared, ready, queued, downloading, importing, imported, failed, cancelled
}

public struct AgentActivity: Identifiable, Sendable {
    public enum Status: String, Sendable { case running, succeeded, failed, cancelled }
    public let id = UUID()
    public var toolName: String
    public var subject: String?
    public var status: Status = .running
    public var cardIDs: [UUID] = []
    public var resultCount: Int? { status == .succeeded ? cardIDs.count : nil }
    public var isTruncated = false
    public var message: String?
    public init(toolName: String) { self.toolName = toolName }
}

public struct AgentPresentedResult: Identifiable, Sendable {
    public enum Purpose: String, Sendable {
        case recommendation, citation, match, navigation, importAction, readingNote, removal, localImport
    }
    /// The identifier of the registered card, which owns the source and any subsequent import state.
    public let id: UUID
    public let purpose: Purpose
    public let reason: String?
    public init(id: UUID, purpose: Purpose, reason: String? = nil) {
        self.id = id
        self.purpose = purpose
        self.reason = reason
    }
}

public struct AgentProcessNote: Identifiable, Sendable {
    public enum Kind: Sendable { case progress, thinking }
    public let id = UUID()
    public let beforeActivityCount: Int
    public let kind: Kind
    public let text: String
    public init(beforeActivityCount: Int, kind: Kind, text: String) {
        self.beforeActivityCount = beforeActivityCount
        self.kind = kind
        self.text = text
    }
}

public struct AgentClarification: Sendable, Equatable {
    public let question: String
    public let options: [String]
    public var reply: String?

    public init(question: String, options: [String]) {
        self.question = question
        self.options = options
    }
}

public struct AgentTurn: Identifiable, Sendable {
    public var id = UUID()
    public var question: String
    public var referencedCardID: UUID?
    public var referencedCardTitle: String?
    public var clarification: AgentClarification?
    public var answer = ""
    public var activities: [AgentActivity] = []
    public var processNotes: [AgentProcessNote] = []
    public var presentedResults: [AgentPresentedResult] = []
    public var cards: [AgentCard] = []
    public var error: String?
    public var isCancelled = false
    public init(question: String) { self.question = question }

    /// Cards remain owned by the turn so later imports update every appearance of a candidate.
    public func cards(for activity: AgentActivity) -> [AgentCard] {
        activity.cardIDs.compactMap { id in cards.first { $0.id == id } }
    }
}

public struct AgentLimits: Sendable {
    /// Rounds in which the model may request tools. One answer-only request may follow.
    public var maxRounds = 16
    public var maxToolCalls = 48
    public var maxArgumentBytes = 4_096
    public var maxResponseBytes = 1_000_000
    public var maxContextBytes = 80_000
    public var maxToolResultBytes = 12_000
    public var maxResults = 12
    public var maxQuestionBytes = 8_000
    public var maxHistoryTurns = 6
    /// Tool definitions to advertise on this request. Standalone clients default to the full catalog.
    public var availableToolNames: Set<String>?
    public init() {}
}

public enum AgentToolBudgetError: Error {
    case batchExceedsRemainingCalls
}

public struct AgentToolCall: Codable, Sendable, Equatable {
    // The Gemini compatibility endpoint attaches a signed continuation to individual tool calls.
    struct ExtraContent: Codable, Sendable, Equatable {
        struct Google: Codable, Sendable, Equatable {
            let thoughtSignature: String
            enum CodingKeys: String, CodingKey { case thoughtSignature = "thought_signature" }
        }
        let google: Google?
    }

    public struct Function: Codable, Sendable, Equatable {
        public var name: String
        public var arguments: String
        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }
    public var id: String
    public var type: String
    public var function: Function
    var extraContent: ExtraContent?
    enum CodingKeys: String, CodingKey {
        case id, type, function
        case extraContent = "extra_content"
    }
    public init(id: String, name: String, arguments: String) {
        self.id = id
        type = "function"
        function = .init(name: name, arguments: arguments)
    }
}

public struct AgentMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String?
    public var toolCalls: [AgentToolCall]?
    public var toolCallID: String?
    public var reasoningContent: String?
    public init(
        role: String, content: String? = nil, toolCalls: [AgentToolCall]? = nil, toolCallID: String? = nil,
        reasoningContent: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.reasoningContent = reasoningContent
    }
    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningContent = "reasoning_content"
    }
}

public protocol AgentCompleting: Sendable {
    func respond(settings: ModelSettings, key: String, messages: [AgentMessage], limits: AgentLimits) async throws
        -> AgentMessage
    func respondStreaming(
        settings: ModelSettings, key: String, messages: [AgentMessage], limits: AgentLimits,
        onPartial: @escaping @Sendable (String) async throws -> Void
    ) async throws -> AgentMessage
}

extension AgentCompleting {
    public func respondStreaming(
        settings: ModelSettings, key: String, messages: [AgentMessage], limits: AgentLimits,
        onPartial: @escaping @Sendable (String) async throws -> Void
    ) async throws -> AgentMessage {
        let result = try await respond(settings: settings, key: key, messages: messages, limits: limits)
        if let text = result.content { try await onPartial(text) }
        return result
    }
}
