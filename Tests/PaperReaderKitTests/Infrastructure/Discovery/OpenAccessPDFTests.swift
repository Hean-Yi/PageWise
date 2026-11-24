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
    var body = "%PDF-1.7\nfixture"
    var redirected = false
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://aclanthology.org/N19-1423.pdf")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: redirected ? URL(string: "https://elsewhere.invalid/file.pdf")! : url,
                statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test func publicationDownloadUsesVerifiedAnthologyIdentityAndStagesPDFOnly() async throws {
    let candidate = publisherRecord(pdf: "https://elsewhere.invalid/wrong-paper.pdf")
    let publication = try await OpenAccessPDFDownloader(transport: PublisherDownloadFixture()).downloadPublication(
        candidate)
    defer { try? FileManager.default.removeItem(at: publication.pdfURL) }
    #expect(try Data(contentsOf: publication.pdfURL) == Data("%PDF-1.7\nfixture".utf8))
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
    let transport = PublisherDownloadFixture(body: redirected ? "%PDF-1.7" : "<html>paywall", redirected: redirected)
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
