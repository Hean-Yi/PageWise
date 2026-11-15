import Foundation

/// A rejected model protocol response; storage, credentials and transport errors remain distinct.
public enum AIReflowFailure: Error, LocalizedError, Sendable, Equatable {
    case invalidStructure

    public var errorDescription: String? {
        switch self {
        case .invalidStructure:
            "模型返回的重排结构格式无效，当前内容未发布；此前已完成的内容已保留，可继续重试。"
        }
    }
}
