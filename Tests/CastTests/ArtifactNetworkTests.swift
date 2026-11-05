import Foundation
import XCTest
@testable import Cast

private final class ArtifactTestProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static func reset() { lock.lock(); requests = []; lock.unlock() }
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let path = request.url!.path
        let status = path == "/expired" ? 401 : path == "/redirect" ? 302 : 200
        let body = path == "/large" ? Data(repeating: 65, count: 131072) : Data([0x50,0x4b,0x03,0x04,0,255,1,2])
        let length = path == "/oversized" ? ArtifactTransferPolicy.maximumBytes + 1 : body.count
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(length)", "Content-Type": "application/zip", "Location": "https://elsewhere.test/file"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ArtifactNetworkTests: XCTestCase {
    private func config() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtifactTestProtocol.self]
        return config
    }
    func testBinaryTransferIsExactAndDoesNotSendGatewayCredentials() async throws {
        ArtifactTestProtocol.reset()
        let data = try await ArtifactDownloader.download(url: URL(string: "https://fixture.test/file")!,
            expectedSize: 8, configuration: config(), progress: { _, _ in })
        XCTAssertEqual(data, Data([0x50,0x4b,0x03,0x04,0,255,1,2]))
        let request = try XCTUnwrap(ArtifactTestProtocol.snapshot().first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }
    func testExpiredRedirectOversizedAndTruncatedDownloadsAreRefused() async {
        for path in ["expired", "redirect", "oversized", "mismatch"] {
            do {
                _ = try await ArtifactDownloader.download(url: URL(string: "https://fixture.test/\(path)")!,
                    expectedSize: path == "mismatch" ? 10 : nil, configuration: config(), progress: { _, _ in })
                XCTFail("Accepted \(path)")
            } catch {}
        }
    }
    func testCancelledTransferCannotReturnAFile() async {
        let config = config()
        let task = Task {
            return try await ArtifactDownloader.download(url: URL(string: "https://fixture.test/large")!,
                expectedSize: 131072, configuration: config, progress: { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do { _ = try await task.value; XCTFail("Cancelled transfer succeeded") } catch {}
    }
}
