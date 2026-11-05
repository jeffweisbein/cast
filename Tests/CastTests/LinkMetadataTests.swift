import Foundation
import XCTest
@testable import Cast

final class LinkMetadataTests: XCTestCase {
    // MARK: - LinkTitleParser

    func testOgTitleBeatsDocumentTitle() {
        let html = """
        <html><head>
        <title>Fallback Title</title>
        <meta property="og:title" content="The Real Title">
        </head><body></body></html>
        """
        XCTAssertEqual(LinkTitleParser.pageTitle(inHTML: html), "The Real Title")
    }

    func testOgTitleAttributeOrderAndQuoteStyle() {
        let reversed = "<meta content='Order Independent' property='og:title'>"
        XCTAssertEqual(LinkTitleParser.pageTitle(inHTML: reversed), "Order Independent")
        let named = "<meta name=\"og:title\" content=\"Named Variant\">"
        XCTAssertEqual(LinkTitleParser.pageTitle(inHTML: named), "Named Variant")
    }

    func testDocumentTitleFallbackCollapsesWhitespace() {
        let html = "<TITLE>\n  Spread\n  Across   Lines  \n</TITLE>"
        XCTAssertEqual(LinkTitleParser.pageTitle(inHTML: html), "Spread Across Lines")
    }

    func testEntitiesDecoded() {
        let html = "<title>Q&amp;A &mdash; Ben&#39;s &#x22;Guide&#x22; &lt;3</title>"
        XCTAssertEqual(LinkTitleParser.pageTitle(inHTML: html), "Q&A — Ben's \"Guide\" <3")
    }

    func testUnknownEntityAndBareAmpersandSurvive() {
        XCTAssertEqual(LinkTitleParser.decodeHTMLEntities("AT&T &unknown; &"), "AT&T &unknown; &")
    }

    func testEmptyOgTitleFallsBackToDocumentTitle() {
        let html = "<meta property=\"og:title\" content=\"  \"><title>Backup</title>"
        XCTAssertEqual(LinkTitleParser.pageTitle(inHTML: html), "Backup")
    }

    func testNoTitleReturnsNil() {
        XCTAssertNil(LinkTitleParser.pageTitle(inHTML: "<html><body><p>no title here</p></body></html>"))
        XCTAssertNil(LinkTitleParser.pageTitle(inHTML: "<title>   </title>"))
    }

    func testUnrelatedMetaTagsIgnored() {
        let html = "<meta property=\"og:description\" content=\"Not this\"><title>Doc</title>"
        XCTAssertEqual(LinkTitleParser.pageTitle(inHTML: html), "Doc")
    }

    func testMetadataFetchPolicyRejectsImplicitPrivateNetworkRequests() throws {
        XCTAssertTrue(LinkMetadataPolicy.canFetch(try XCTUnwrap(URL(string: "https://example.com/post"))))
        XCTAssertFalse(LinkMetadataPolicy.canFetch(try XCTUnwrap(URL(string: "http://localhost:3000/admin"))))
        XCTAssertFalse(LinkMetadataPolicy.canFetch(try XCTUnwrap(URL(string: "http://127.0.0.1/private"))))
        XCTAssertFalse(LinkMetadataPolicy.canFetch(try XCTUnwrap(URL(string: "http://192.168.1.10/status"))))
        XCTAssertFalse(LinkMetadataPolicy.canFetch(try XCTUnwrap(URL(string: "http://100.64.0.1/internal"))))
        XCTAssertFalse(LinkMetadataPolicy.canFetch(try XCTUnwrap(URL(string: "http://[::1]/private"))))
        XCTAssertFalse(LinkMetadataPolicy.canFetch(try XCTUnwrap(URL(string: "http://[::ffff:192.168.1.1]/private"))))
        XCTAssertFalse(LinkMetadataPolicy.canFetch(try XCTUnwrap(URL(string: "http://[::ffff:10.0.0.1]/private"))))
        XCTAssertFalse(LinkMetadataPolicy.canFetch(try XCTUnwrap(URL(string: "https://user:pass@example.com"))))
    }

    // MARK: - LinkMetadataStore disk cache

    func testDiskCacheRoundTripAcrossInstances() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastLinkMetaTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://example.com/post")!

        let first = LinkMetadataStore(root: root)
        await first.seedTitleForTesting("Cached Page", for: url)
        let second = LinkMetadataStore(root: root)
        let hit = await second.cachedTitleForTesting(for: url)
        XCTAssertEqual(hit, "Cached Page")
    }
}

extension LinkMetadataStore {
    /// Test seams: inject a title through the persistence path, and read back through the
    /// cache lookup path without touching the network.
    func seedTitleForTesting(_ title: String, for url: URL) {
        self.recordFetchedTitle(title, key: url.absoluteString)
    }

    func cachedTitleForTesting(for url: URL) -> String? {
        self.cachedTitle(key: url.absoluteString)
    }
}
