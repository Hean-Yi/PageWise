import Foundation

/// Interleave the indexes' ranked lists. Only registered identities and explicit preprint relations join records.
enum PaperDiscoveryRanking {
    static func merge(_ lists: [[PaperCandidate]], query: String?, limit: Int) -> [PaperCandidate] {
        var orderedIDs: [String] = []
        var records: [String: PaperCandidate] = [:]
        for row in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where list.indices.contains(row) {
                guard let record = list[row].verified else { continue }
                let id = versionKey(record)
                if let earlier = records[id] {
                    var best = earlier.pdfURL == nil && record.pdfURL != nil ? record : earlier
                    best.relatedArxivID = best.relatedArxivID ?? earlier.relatedArxivID ?? record.relatedArxivID
                    records[id] = best
                } else {
                    records[id] = record
                    orderedIDs.append(id)
                }
            }
        }

        var preprintsByDOI: [String: Set<String>] = [:]
        for record in records.values where record.source == .arxiv {
            if let doi = record.doi, let key = record.preprintID.map(preprintKey) {
                preprintsByDOI[doi, default: []].insert(key)
            }
        }
        var groups: [String: [PaperCandidate]] = [:]
        var order: [String] = []
        for id in orderedIDs {
            guard let record = records[id] else { continue }
            let linked = record.doi.flatMap { preprintsByDOI[$0] }
            let key = record.preprintID.map(preprintKey) ?? (linked?.count == 1 ? linked?.first : nil) ?? id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(record)
        }
        let result: [PaperCandidate] = order.compactMap { key in
            guard var versions = groups[key] else { return nil }
            let preprints = versions.compactMap(\.linkedPreprint)
            for preprint in preprints {
                let existing = versions.filter { $0.source == .arxiv }.compactMap(\.preprintID)
                guard let id = preprint.preprintID, !existing.contains(id),
                    existing.isEmpty || ArxivClient.versionedIdentifier(preprint.id) != nil
                else { continue }
                versions.append(preprint)
            }
            if versions.contains(where: { ArxivClient.versionedIdentifier($0.id) != nil }) {
                versions.removeAll { $0.source == .arxiv && ArxivClient.versionedIdentifier($0.id) == nil }
            }
            // Prefer a usable full text, retaining the published and preprint choices on one card.
            let primary = versions.firstIndex { $0.pdfURL != nil } ?? 0
            var card = versions.remove(at: primary)
            card.alternateVersions = versions
            return card
        }
        guard let query else { return Array(result.prefix(limit)) }
        let title = ArxivClient.normalized(query)
        let doi = PaperCandidate.normalizedDOI(query.replacingOccurrences(of: "https://doi.org/", with: ""))
        // Promote exact titles and DOIs, keeping the original rank of the remaining records.
        var exact: [PaperCandidate] = []
        var partial: [PaperCandidate] = []
        for card in result {
            if ([card] + card.alternateVersions).contains(where: {
                ArxivClient.normalized($0.title) == title || (doi != nil && $0.doi == doi)
            }) {
                exact.append(card)
            } else {
                partial.append(card)
            }
        }
        return Array((exact + partial).prefix(limit))
    }

    private static func preprintKey(_ id: String) -> String {
        "arxiv:" + id.replacingOccurrences(of: #"v[1-9][0-9]*$"#, with: "", options: .regularExpression).lowercased()
    }

    private static func versionKey(_ record: PaperCandidate) -> String {
        if record.source == .arxiv, let identifier = record.preprintID {
            return "arxiv-version:" + identifier.lowercased()
        }
        return record.doi.map { "doi:" + $0 } ?? record.id
    }
}
