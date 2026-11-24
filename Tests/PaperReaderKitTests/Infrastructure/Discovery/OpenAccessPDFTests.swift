import Foundation
import Testing

@testable import PaperReaderKit

private func publisherRecord(
    doi: String = "10.18653/v1/n19-1423", pdf: String? = nil, source: PaperSearchSource = .crossref
) -> PaperCandidate {
    PaperCandidate(
        id: "https://doi.org/" + doi, title: "Test publication", authors: "", year: "2025",
        pdfURL: pdf.flatMap(URL.init(string:)), source: source, doi: doi)
}

private struct PublisherDownloadFixture: HTTPTransport {
    var body: Data
    var redirected = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://aclanthology.org/N19-1423.pdf")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        return (
            body,
            HTTPURLResponse(
                url: redirected ? URL(string: "https://elsewhere.invalid/file.pdf")! : url,
                statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func publicationDownloadUsesVerifiedAnthologyIdentityAndStagesPDFOnly() async throws {
    let candidate = publisherRecord(pdf: "https://elsewhere.invalid/wrong-paper.pdf")
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: source) }
    try DemoPaper.write(to: source)
    let pdf = try Data(contentsOf: source)
    let publication = try await OpenAccessPDFDownloader(transport: PublisherDownloadFixture(body: pdf))
        .downloadPublication(candidate)
    defer { try? FileManager.default.removeItem(at: publication.pdfURL) }
    #expect(try Data(contentsOf: publication.pdfURL) == pdf)
    #expect(publication.candidate.id == candidate.id)
    #expect(publication.texArchive == nil)
    #expect(
        publisherRecord(doi: "10.18653/2026.findings-emnlp.1727").verified?.pdfURL?.absoluteString
            == "https://aclanthology.org/2026.findings-emnlp.1727.pdf")
    #expect(
        publisherRecord(doi: "10.18653/v1/2023.acl-long.1").verified?.pdfURL?.absoluteString
            == "https://aclanthology.org/2023.acl-long.1.pdf")
}

@Test(arguments: [true, false]) func publisherDownloadsRejectRedirectOrNonPDF(redirected: Bool) async throws {
    let transport = PublisherDownloadFixture(
        body: Data((redirected ? "%PDF-1.7" : "<html>paywall").utf8), redirected: redirected)
    await #expect(throws: (any Error).self) {
        try await OpenAccessPDFDownloader(transport: transport).downloadPublication(publisherRecord())
    }
}

@Test(arguments: [
    "https://127.0.0.1/private.pdf", "https://proceedings.mlr.press.invalid/file.pdf",
    "http://proceedings.mlr.press/v20/example.pdf", "https://openreview.net/pdf?id=one&id=two",
    "https://user@proceedings.mlr.press/v20/example.pdf", "https://arxiv.org/pdf/2401.00001v1",
])
func unsafeOrUnboundOpenAccessLinkRetainsOnlyPublicationPage(link: String) throws {
    let record = try #require(publisherRecord(doi: "10.1234/example", pdf: link, source: .semanticScholar).verified)
    #expect(!record.canDownload)
    #expect(record.landingURL?.host == "doi.org")
}

@Test func publisherMetadataAloneCannotAuthorizeASemanticScholarOpenCopy() {
    let link = "https://proceedings.mlr.press/v42/example.pdf"
    #expect(publisherRecord(doi: "10.1234/example", pdf: link, source: .semanticScholar).canDownload)
    #expect(!publisherRecord(doi: "10.1234/example", pdf: link, source: .crossref).canDownload)
    #expect(!publisherRecord(doi: "10.1234/example", pdf: link, source: .dblp).canDownload)
}

@Test func crossrefLicensedFullTextLinkMustNameItsOwnDOIOnThePublisher() {
    let doi = "10.1007/test-article"
    let registered = "https://link.springer.com/content/pdf/10.1007/test-article.pdf"
    #expect(publisherRecord(doi: doi, pdf: registered).canDownload)
    #expect(!publisherRecord(doi: doi, pdf: "https://link.springer.com/content/pdf/10.1007/different.pdf").canDownload)
}

private actor IndexedCopyTransport: HTTPTransport {
    let openAlex: String
    let scholar: String
    let pdf: Data
    private(set) var requests: [URL] = []

    init(openAlex: String, scholar: String = "{}", pdf: Data = Data()) {
        self.openAlex = openAlex
        self.scholar = scholar
        self.pdf = pdf
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        requests.append(url)
        let body: Data
        switch url.host {
        case "api.openalex.org": body = Data(openAlex.utf8)
        case "api.semanticscholar.org": body = Data(scholar.utf8)
        case "journals.plos.org", "zenodo.org": body = pdf
        case "link.springer.com": body = Data("<html>Sign in</html>".utf8)
        default: throw URLError(.unsupportedURL)
        }
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func selectedDOIResolvesAnOpenCopyWithItsOriginalIdentityAndEdition() async throws {
    let candidate = publisherRecord(doi: "10.1371/journal.pone.123456")
    #expect(candidate.canAttemptDownload && !candidate.canDownload)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: file) }
    try DemoPaper.write(to: file)
    let transport = IndexedCopyTransport(
        openAlex: #"""
            {"doi":"https://doi.org/10.1371/journal.pone.123456","locations":[
              {"version":"acceptedVersion","is_oa":true,"pdf_url":"https://zenodo.org/records/4/files/paper.pdf"},
              {"version":"publishedVersion","is_oa":false,"pdf_url":"https://zenodo.org/records/5/files/paper.pdf"},
              {"version":"publishedVersion","is_oa":true,"pdf_url":"https://127.0.0.1/not-a-paper.pdf"},
              {"version":"publishedVersion","is_oa":true,"doi":"10.1234/wrong","pdf_url":"https://zenodo.org/records/6/files/paper.pdf"},
              {"version":"publishedVersion","is_oa":true,"pdf_url":"https://journals.plos.org/plosone/article/file?id=10.1371/journal.pone.123456&type=printable"}
            ]}
            """#,
        pdf: try Data(contentsOf: file))
    let result = try await FederatedPaperDiscovery(arxiv: ArxivClient(), transport: transport)
        .downloadPublication(candidate)
    defer { try? FileManager.default.removeItem(at: result.pdfURL) }
    #expect(await transport.requests.compactMap(\.host) == ["api.openalex.org", "journals.plos.org"])
    #expect(result.candidate.id == candidate.id && result.candidate.verified?.canDownload == true)
    #expect(result.sourceNotice?.contains("出版版") == true)
    #expect(try Data(contentsOf: result.pdfURL) == Data(contentsOf: file))
}

@Test func failedDirectDownloadFallsBackByExactDOIAndHonorsCancellation() async throws {
    let candidate = publisherRecord(
        doi: "10.1007/paper", pdf: "https://link.springer.com/content/pdf/10.1007/paper.pdf")
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: file) }
    try DemoPaper.write(to: file)
    let transport = IndexedCopyTransport(
        openAlex: #"{"doi":"https://doi.org/10.1234/wrong","locations":[]}"#,
        scholar:
            #"{"externalIds":{"DOI":"10.1007/PAPER"},"openAccessPdf":{"url":"https://zenodo.org/records/42/files/paper.pdf"}}"#,
        pdf: try Data(contentsOf: file))
    let downloader = IndexedOpenCopies(transport: transport)
    let result = try await downloader.download(candidate)
    defer { try? FileManager.default.removeItem(at: result.pdfURL) }
    let hosts = await transport.requests.compactMap(\.host)
    #expect(hosts == ["link.springer.com", "api.openalex.org", "api.semanticscholar.org", "zenodo.org"])
    #expect(result.candidate.id == candidate.id && result.sourceNotice?.contains("Semantic Scholar") == true)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await downloader.download(candidate)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await transport.requests.compactMap(\.host) == hosts)
}

@Test(arguments: [false, true]) func closedOrMismatchedIndexNeverDownloadsOrMisreportsACompleteSearch(mismatch: Bool)
    async throws
{
    let doi = "10.1234/selected"
    let replyDOI = mismatch ? "10.1234/different" : doi
    let transport = IndexedCopyTransport(
        openAlex: #"{"doi":"https://doi.org/\#(replyDOI)","locations":[]}"#,
        scholar: #"{"externalIds":{"DOI":"\#(replyDOI)"},"openAccessPdf":{"url":""}}"#)
    do {
        _ = try await IndexedOpenCopies(transport: transport).download(publisherRecord(doi: doi))
        Issue.record("Unexpected download")
    } catch let error as ReaderError {
        #expect(error.localizedDescription.contains(mismatch ? "暂时无法访问" : "暂未提供"))
    }
    #expect(await transport.requests.count == 2)
}
