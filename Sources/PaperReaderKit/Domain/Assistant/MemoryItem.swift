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
    public var createdAt = Date() {
        didSet {
            if validFrom == oldValue { validFrom = createdAt }
        }
    }
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
    /// SHA-256 of the word-boundary canonical key (`MemoryDedupKey`), retaining zero plaintext so
    /// deleted/edited memories cannot resurrect via simple bilingual paraphrases.
    private var canonicalFingerprint: String?
    private var forgottenCanonicalFingerprint: String?

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

    /// Create an agent-authored revision of an automatic memory while preserving its origin and
    /// unverified (`userEdited == false`) provenance so silent tool updates never masquerade as
    /// reader-edited endorsements.
    public static func revisedAutomatic(
        from original: MemoryItem, id: UUID = UUID(), statement: String, at date: Date = Date()
    ) -> MemoryItem {
        let cleaned = strippedPrefix(statement)
        var item = MemoryItem(text: Self.automaticPrefix + cleaned, sourceID: original.sourceID)
        item.id = id
        item.librarySource = original.librarySource
        item.preference = original.preference
        item.createdAt = date
        item.validFrom = date
        item.userEdited = false
        return item
    }

    public static func strippedPrefix(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix(Self.automaticPrefix) {
            value = String(value.dropFirst(Self.automaticPrefix.count))
        } else if value.hasPrefix(Self.paperObservationPrefix) {
            value = String(value.dropFirst(Self.paperObservationPrefix.count))
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func sameResearchContent(as other: MemoryItem) -> Bool {
        id == other.id
            && text == other.text
            && sourceID == other.sourceID
            && librarySource == other.librarySource
            && preference == other.preference
            && correctionRevision == other.correctionRevision
            && evidenceFingerprint == other.evidenceFingerprint
            && userEdited == other.userEdited
            && deleted == other.deleted
            && createdAt == other.createdAt
            && validFrom == other.validFrom
            && invalidAt == other.invalidAt
            && supersededBy == other.supersededBy
            && originalFingerprint == other.originalFingerprint
            && forgottenFingerprint == other.forgottenFingerprint
    }

    public mutating func recordRecall(at date: Date = Date()) {
        guard isActive else { return }
        lastRecalledAt = date
        recallCount = (recallCount ?? 0) + 1
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

    public static let automaticPrefix = "AI 整理（待核实）："
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
        self.validFrom = createdAt
        if text.hasPrefix(Self.automaticPrefix) {
            originalFingerprint = Self.fingerprint(text)
            canonicalFingerprint = Self.canonicalHash(text)
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
        let visibleCanonical = Self.canonicalHash(text)
        forgottenCanonicalFingerprint = visibleCanonical == canonicalFingerprint ? nil : visibleCanonical
        text = ""
        if case .reader = librarySource { librarySource = .reader(quote: "") }
        deleted = true
        return true
    }

    var rejectedFingerprints: [String] {
        guard userEdited || deleted else { return [] }
        return [originalFingerprint, forgottenFingerprint, evidenceFingerprint].compactMap { $0 }
    }

    func suppressesAutomaticProposition(_ fingerprint: String, canonical: String? = nil) -> Bool {
        if originalFingerprint == fingerprint || forgottenFingerprint == fingerprint { return true }
        if let canonical, userEdited || deleted,
            canonicalFingerprint == canonical || forgottenCanonicalFingerprint == canonical
        {
            return true
        }
        return !deleted && (userEdited || originalFingerprint == nil) && Self.fingerprint(text) == fingerprint
    }

    private mutating func preserveOriginalFingerprint() {
        if originalFingerprint == nil && !userEdited && !deleted {
            originalFingerprint = Self.fingerprint(text)
            canonicalFingerprint = Self.canonicalHash(text)
        }
    }

    static func canonicalHash(_ text: String) -> String? {
        let key = MemoryDedupKey.key(text)
        guard key.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
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
