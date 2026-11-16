import Foundation

/// A rejected model protocol response; storage, credentials and transport errors remain distinct.
public enum AIReflowFailure: Error, LocalizedError, Sendable, Equatable {
    case invalidStructure

    public var errorDescription: String? {
        switch self {
        case .invalidStructure:
            "本页仍未能完成整理，已暂停生成。已完成内容和阅读位置已保留，原版可继续阅读。"
        }
    }
}
