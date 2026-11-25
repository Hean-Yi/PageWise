import CryptoKit
import Foundation

public struct MemoryItem: Identifiable, Codable, Sendable, Equatable {
    public enum LibrarySource: Codable, Sendable, Equatable {
        case reader(quote: String)
        case note(paperID: UUID, modifiedAt: Date)
    }

    public private(set) var preference: ReaderPreference?
    public private(set) var correctionRevision: UUID?
    public var isResponsePreference: Bool { preference != nil }

    public init(preference: ReaderPreference, statement: String, sourceID: UUID, libraryTurn: Bool) {
        self.init(text: statement, sourceID: sourceID)
        self.preference = preference
        if libraryTurn { librarySource = .reader(quote: statement) }
        originalFingerprint = Self.fingerprint(statement)
    }

    public var id = UUID()
    public var text: String
    public var sourceID: UUID
    public private(set) var librarySource: LibrarySource?
    private(set) var evidenceFingerprint: String?
    public var userEdited = false
    public var deleted = false
    public var createdAt = Date()
    /// Older rows have no fingerprint. Capture a still-visible original before its first edit or deletion.
    public private(set) var originalFingerprint: String?
    /// When deleting a correction, suppress the last visible wording as well as the automatic original.
    private var forgottenFingerprint: String?

    static let automaticPrefix = "AI 整理（待核实）："

    public init(text: String, sourceID: UUID) {
        self.text = text
        self.sourceID = sourceID
        if text.hasPrefix(Self.automaticPrefix) {
            originalFingerprint = Self.fingerprint(text)
        }
    }

    init(question: String, sourceID: UUID, source: LibrarySource, evidence: String) {
        self.init(text: Self.automaticPrefix + question, sourceID: sourceID)
        librarySource = source
        evidenceFingerprint = Self.fingerprint(evidence)
    }

    @discardableResult public mutating func correct(to replacement: String) -> Bool {
        guard !deleted, replacement != text || !userEdited else { return false }
        preserveOriginalFingerprint()
        text = replacement
        userEdited = true
        preference = preference?.corrected(using: replacement)
        correctionRevision = UUID()
        return true
    }

    @discardableResult public mutating func forget() -> Bool {
        guard !deleted else { return false }
        preserveOriginalFingerprint()
        let visible = Self.fingerprint(text)
        forgottenFingerprint = visible == originalFingerprint ? nil : visible
        text = ""
        if case .reader = librarySource { librarySource = .reader(quote: "") }
        deleted = true
        return true
    }

    var rejectedFingerprints: [String] {
        guard userEdited || deleted else { return [] }
        return [originalFingerprint, forgottenFingerprint, evidenceFingerprint].compactMap { $0 }
    }

    func suppressesAutomaticProposition(_ fingerprint: String) -> Bool {
        if originalFingerprint == fingerprint || forgottenFingerprint == fingerprint { return true }
        return !deleted && (userEdited || originalFingerprint == nil) && Self.fingerprint(text) == fingerprint
    }

    private mutating func preserveOriginalFingerprint() {
        if originalFingerprint == nil && !userEdited && !deleted { originalFingerprint = Self.fingerprint(text) }
    }

    private static func fingerprint(_ text: String) -> String? {
        let proposition = text.hasPrefix(automaticPrefix) ? String(text.dropFirst(automaticPrefix.count)) : text
        let words = proposition.folding(
            options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")
        )
        .precomposedStringWithCanonicalMapping
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var key = words[...]
        while let last = key.last, "。！？!?.… ".contains(last) { key = key.dropLast() }
        guard key.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
