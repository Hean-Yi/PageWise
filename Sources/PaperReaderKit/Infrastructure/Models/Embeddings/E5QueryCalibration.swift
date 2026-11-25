import Accelerate
import Foundation
import NaturalLanguage

/// Mean of eight generic, parallel queries per language, encoded with the exact shipped
/// revision. Subtracting this background on the query side reduces same-language hub bias.
private struct E5QueryCalibration: Decodable {
    let revision: String
    let centers: [String: [Float]]
    static let shipped: Self? = {
        guard
            let url = Bundle.module.url(
                forResource: "e5-query-centers", withExtension: "json", subdirectory: "Embeddings"),
            let bytes = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: bytes)
    }()

    func center(for text: String) -> [Float]? {
        // Short Chinese queries frequently mix English terminology. Other scripts retain native cosine.
        let language: String
        if text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
            if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return nil }
            language = "zh"
        } else {
            guard NLLanguageRecognizer.dominantLanguage(for: text) == .english else { return nil }
            language = "en"
        }
        return centers[language]
    }
}

extension DeviceSemanticEncoder {
    public func retrievalQuery(_ text: String) async throws -> (vector: [Float], minimum: Float)? {
        guard let vector = try await encode([text], as: .query).first else { return nil }
        guard let calibration = E5QueryCalibration.shipped, calibration.revision == identifier,
            let center = calibration.center(for: text), center.count == vector.count
        else { return (vector, 0.82) }
        return (vDSP.subtract(vector, center), 0.05)
    }
}
