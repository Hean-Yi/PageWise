import CryptoKit
import Foundation

public struct MemoryItem: Identifiable, Codable, Sendable, Equatable {
    public enum LibrarySource: Codable, Sendable, Equatable {
        case reader(quote: String)
        case note(paperID: UUID, modifiedAt: Date)
        case paper(paperID: UUID)
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
    /// Bi-temporal validity window for real-world fact evolution, separate from system `createdAt`.
    public var validFrom: Date?
    public var invalidAt: Date?
    public var supersededBy: UUID?
    /// Lightweight salience tracking for automatic memories; user-edited items and explicit
    /// preferences are immune to decay.
    public var lastRecalledAt: Date?
    public var recallCount: Int?
    /// Older rows have no fingerprint. Capture a still-visible original before its first edit or deletion.
    public private(set) var originalFingerprint: String?
    /// When deleting a correction, suppress the last visible wording as well as the automatic original.
    private var forgottenFingerprint: String?

    public var isActive: Bool { !deleted && invalidAt == nil && !text.isEmpty }

    public var revisionFingerprint: String {
        let payload =
            "\(id.uuidString)|\(deleted ? 1 : 0)|\(userEdited ? 1 : 0)|\(correctionRevision?.uuidString ?? "")|"
            + "\(invalidAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "")|\(text)"
        return SHA256.hash(data: Data(payload.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func matchesRevision(_ expected: String) -> Bool {
        let normalized = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count >= 8 else { return false }
        return revisionFingerprint == normalized || revisionFingerprint.hasPrefix(normalized)
    }

    /// Mark an automatic memory as superseded by a newer statement without erasing its history.
    @discardableResult public mutating func supersede(by replacementID: UUID, at date: Date = Date()) -> Bool {
        guard !deleted, !userEdited, invalidAt == nil, replacementID != id else { return false }
        invalidAt = date
        supersededBy = replacementID
        return true
    }

    /// Salience multiplier in `[0.35, 1.15]`. User-edited memories and explicit preferences never decay.
    public func salienceWeight(at now: Date = Date()) -> Double {
        if userEdited || isResponsePreference { return 1.0 }
        let anchor = max(validFrom ?? createdAt, lastRecalledAt ?? createdAt)
        let ageDays = max(0, now.timeIntervalSince(anchor) / 86_400)
        // 60-day half-life with a floor so older relevant research clues remain retrievable.
        let decayed = max(0.35, pow(0.5, ageDays / 60.0))
        let boost = min(0.15, Double(max(0, recallCount ?? 0)) * 0.03)
        return min(1.15, decayed + boost)
    }

    static let automaticPrefix = "AI 整理（待核实）："
    public static let paperObservationPrefix = "AI 阅读记录："

    /// A reading observation is grounded in the paper itself, not in a chat turn.
    public init(paperID: UUID, statement: String) {
        self.init(text: Self.paperObservationPrefix + statement, sourceID: paperID)
        librarySource = .paper(paperID: paperID)
        // Reading observations need the same tombstone behavior as automatic questions.
        originalFingerprint = Self.fingerprint(statement)
    }

    /// A statement proposed by an agent with an explicit reader/note source.
    public init(agentStatement: String, sourceID: UUID, source: LibrarySource?) {
        self.init(text: Self.automaticPrefix + agentStatement, sourceID: sourceID)
        librarySource = source
    }

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
        guard !deleted, replacement != text else { return false }
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
