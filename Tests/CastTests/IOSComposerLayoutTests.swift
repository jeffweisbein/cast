import Foundation
import XCTest

/// The test suite is macOS-hosted, so it cannot instantiate the iOS-only
/// TextField branch. Keep a narrow source guard around the modifiers that
/// determine whether the empty field takes the detached VStack's proposal.
final class IOSComposerLayoutTests: XCTestCase {
    func testIOSComposerUsesIntrinsicOneLineHeightAndRetainsMultilineGrowth() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/App/ChatView.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "TextField(\"Message the fleet…\", text: self.$draft, axis: .vertical)"))
        let suffix = source[start.lowerBound...]
        let end = try XCTUnwrap(suffix.range(of: "#endif"))
        let composerField = String(suffix[..<end.lowerBound])

        XCTAssertTrue(composerField.contains(".lineLimit(1 ... 12)"))
        XCTAssertTrue(composerField.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(composerField.contains(".frame(maxHeight:"))
    }
}
