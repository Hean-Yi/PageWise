import Foundation
import PDFKit

/// Resolves publisher records to retrievable open copies. Metadata and PDF actions use separate checks.
public struct OpenAccessPDFDownloader: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }

    public static func verifiedURL(for candidate: PaperCandidate) -> URL? {
        guard candidate.source != .arxiv else { return nil }
        if candidate.indexedCopy == nil, let doi = candidate.doi, let acl = anthologyPDF(doi: doi) { return acl }
        guard let url = candidate.pdfURL else { return nil }
        let indexed = candidate.indexedCopy?.candidateID == candidate.id && candidate.indexedCopy?.url == url
        // A DOI lookup can locate copies that weren't in the original bibliographic record.
        guard indexed || [.crossref, .semanticScholar].contains(candidate.source),
            url.scheme == "https",
            let host = url.host?.lowercased(), url.port == nil, url.user == nil, url.password == nil,
            url.fragment == nil, url.absoluteString.utf8.count <= 2_048, !url.pathComponents.contains(".."),
            !url.pathComponents.contains("."), !url.path.contains("\\"), !url.path.contains("//")
        else { return nil }
        let path = (url.path.removingPercentEncoding ?? url.path).lowercased()
        if indexed, let doi = candidate.doi,
            let doiStart = path.range(of: #"/10\.[0-9]{4,9}/"#, options: .regularExpression)
        {
            let suffix = String(path[doiStart.lowerBound...])
            guard ["/" + doi, "/" + doi + ".pdf", "/" + doi + "/pdf", "/" + doi + ".full.pdf"].contains(suffix) else {
                return nil
            }
        }
        if !indexed && candidate.source == .crossref && host != "journals.plos.org" {
            guard let doi = candidate.doi,
                ["/" + doi, "/" + doi + ".pdf", "/" + doi + "/pdf"].contains(where: path.hasSuffix)
            else { return nil }
        }
        switch host {
        case "openreview.net":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard url.path == "/pdf", items?.count == 1, items?.first?.name == "id",
                items?.first?.value?.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
            else { return nil }
        case "journals.plos.org":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard url.path.hasSuffix("/article/file"), items.count == 2,
                let doi = candidate.doi, doi.hasPrefix("10.1371/"),
                items.contains(URLQueryItem(name: "id", value: doi)),
                items.contains(URLQueryItem(name: "type", value: "printable"))
            else { return nil }
        case "proceedings.mlr.press", "jmlr.org", "www.jmlr.org", "papers.neurips.cc", "proceedings.neurips.cc",
            "openaccess.thecvf.com", "aclanthology.org", "link.springer.com", "www.nature.com", "mdpi-res.com",
            "biorxiv.org", "www.biorxiv.org", "medrxiv.org", "www.medrxiv.org", "pmc.ncbi.nlm.nih.gov",
            "pdfs.semanticscholar.org":
            guard url.path.lowercased().hasSuffix(".pdf") else { return nil }
        case "dl.acm.org", "journals.sagepub.com", "onlinelibrary.wiley.com", "www.tandfonline.com", "www.science.org",
            "journals.aps.org", "pubs.acs.org":
            guard path.contains("/pdf/") || path.contains("/pdfdirect/") else { return nil }
        case "iopscience.iop.org":
            guard path.hasPrefix("/article/") && path.hasSuffix("/pdf") else { return nil }
        case "zenodo.org":
            guard indexed, path.range(of: #"^/records?/[0-9]+/files/[^/]+\.pdf$"#, options: .regularExpression) != nil
            else { return nil }
        case "hal.science", "hal.archives-ouvertes.fr", "inria.hal.science":
            guard indexed,
                path.range(
                    of: #"^/[a-z-]+-[0-9]+(?:v[0-9]+)?/(?:document|file/[^/]+\.pdf)$"#,
                    options: .regularExpression) != nil
            else { return nil }
        case "www.frontiersin.org":
            guard url.path.hasPrefix("/journals/") || url.path.hasPrefix("/articles/"),
                url.path.hasSuffix("/pdf")
            else { return nil }
        default: return nil
        }
        return url
    }

    private static func anthologyPDF(doi: String) -> URL? {
        let prefix = "10.18653/"
        let doi = doi.lowercased()
        guard doi.hasPrefix(prefix) else { return nil }
        let suffix = doi.dropFirst(prefix.count)
        let identifier = String(suffix.hasPrefix("v1/") ? suffix.dropFirst(3) : suffix)
        let slug: String
        if suffix.hasPrefix("v1/"),
            identifier.range(of: #"^[a-z][0-9]{2}-[0-9]{4,5}$"#, options: .regularExpression) != nil
        {
            slug = identifier.uppercased()
        } else if identifier.range(of: #"^20[0-9]{2}\.[a-z0-9][a-z0-9-]*\.[0-9]+$"#, options: .regularExpression) != nil
        {
            slug = identifier
        } else {
            return nil
        }
        return URL(string: "https://aclanthology.org/" + slug + ".pdf")
    }

    public func downloadPublication(_ candidate: PaperCandidate) async throws -> DownloadedPublication {
        guard candidate.source != .arxiv, let verified = candidate.verified, let pdf = verified.pdfURL else {
            throw ReaderError.message("未取得可验证的开放全文地址，可查看出版页。")
        }
        try Task.checkCancellation()
        var request = URLRequest(url: pdf, timeoutInterval: 20)
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        let (file, response) = try await transport.downloadFile(for: request, maximumBytes: 50_000_000)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard response.statusCode == 200, response.url == pdf else {
            throw ReaderError.message("此开放全文暂时无法直接下载，可查看出版页。")
        }
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        guard try reader.read(upToCount: 1_024)?.range(of: Data("%PDF-".utf8)) != nil,
            let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0
        else {
            throw ReaderError.message("来源未返回可阅读的 PDF，可查看出版页。")
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try FileManager.default.moveItem(at: file, to: target)
        return DownloadedPublication(pdfURL: target, candidate: verified, sourceNotice: verified.indexedCopy?.notice)
    }
}
