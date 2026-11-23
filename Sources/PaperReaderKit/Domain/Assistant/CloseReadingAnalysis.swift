import Foundation

public enum CloseReadingDimension: String, CaseIterable, Codable, Sendable {
    case thesis, concept, evidence, rebuttal, method

    public var title: String {
        switch self {
        case .thesis: "核心论点"
        case .concept: "概念与术语"
        case .evidence: "实证证据与数据"
        case .rebuttal: "让步与反驳"
        case .method: "方法论"
        }
    }
    public var color: AnnotationColor {
        switch self {
        case .thesis: .yellow
        case .concept: .red
        case .evidence: .blue
        case .rebuttal: .green
        case .method: .purple
        }
    }
}

public enum CloseReadingStage: String, CaseIterable, Codable, Sendable {
    case question, thesis, evidence, rebuttal, conclusion

    public var title: String {
        switch self {
        case .question: "问题"
        case .thesis: "论点"
        case .evidence: "证据"
        case .rebuttal: "反驳"
        case .conclusion: "结论"
        }
    }
}

public struct CloseReadingReference: Sendable {
    public let evidence: Evidence
    public let quote: String
    public let label: String
}

public struct CloseReadingAnnotation: Sendable {
    public let dimension: CloseReadingDimension
    public let source: Evidence
    public let quote: String
    public let markdown: String
    public let references: [CloseReadingReference]
}

public struct CloseReadingOutlineItem: Sendable {
    public let stage: CloseReadingStage
    public let text: String
    public let references: [CloseReadingReference]
}

public struct CloseReadingAnalysis: Sendable {
    public let annotations: [CloseReadingAnnotation]
    public let outline: [CloseReadingOutlineItem]
    public let coverage: String
}
