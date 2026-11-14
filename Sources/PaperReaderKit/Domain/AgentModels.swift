import Foundation

/// All Agent source pages are one-based; stored TextBlock pages remain zero-based.
public struct AgentCard: Identifiable, Sendable {
    public enum Kind: String, Sendable { case localPaper, evidence, onlineCandidate, navigation }
    public var id = UUID()
    public var kind: Kind
    public var title: String
    public var subtitle = ""
    public var authors: String? = nil
    public var year: String? = nil
    public var excerpt = ""
    public var sourcePage: Int?
    public var paperID: UUID?
    public var blockID: UUID?
    public var candidateID: String?
    public var sourceURL: URL?
    public var importState: AgentImportState = .unprepared
    public var importError: String?
    public var canImport: Bool {
        candidateID != nil && [.unprepared, .ready, .failed, .cancelled].contains(importState)
    }
    public var canOpen: Bool { paperID != nil }
    public init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }
}

public enum AgentImportState: String, Sendable {
    case unprepared, ready, downloading, importing, imported, failed, cancelled
}

public struct AgentActivity: Identifiable, Sendable {
    public enum Status: String, Sendable { case running, succeeded, failed }
    public var id = UUID()
    public var toolName: String
    public var status: Status = .running
    public var resultCount: Int?
    public var message: String?
    public init(toolName: String) { self.toolName = toolName }
}

public struct AgentTurn: Identifiable, Sendable {
    public var id = UUID()
    public var question: String
    public var answer = ""
    public var activities: [AgentActivity] = []
    public var cards: [AgentCard] = []
    public var error: String?
    public var isCancelled = false
    public init(question: String) { self.question = question }
}

public struct AgentLimits: Sendable {
    public var maxRounds = 6
    public var maxToolCalls = 16
    public var maxArgumentBytes = 4_096
    public var maxResponseBytes = 1_000_000
    public var maxContextBytes = 80_000
    public var maxToolResultBytes = 12_000
    public var maxResults = 8
    public var maxQuestionBytes = 8_000
    public var maxHistoryTurns = 6
    public init() {}
}

public struct AgentToolCall: Codable, Sendable, Equatable {
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
}
