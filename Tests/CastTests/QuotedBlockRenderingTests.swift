// Cast — headless layout smoke checks for the transcript's copy affordances.
//
// A theme block style is a closure SwiftUI only runs when a message of that shape is
// rendered, so a green compile says nothing about whether the blockquote override lays
// out. `ImageRenderer` runs the real hierarchy and gives a size back, which is enough to
// catch a degenerate frame or a trap inside the closure without a device. Interaction —
// hover reveal, drag-to-select, the iOS callout — is not observable here.
import SwiftUI
import XCTest

@testable import Cast

@MainActor
final class QuotedBlockRenderingTests: XCTestCase {
    private let width: CGFloat = 600

    private func renderedHeight(markdown: String) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: MarkdownBody(text: markdown)
                .frame(width: self.width))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "MarkdownBody produced no rendering")
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        return image.size.height
    }

    func testPlainResponseRenders() throws {
        XCTAssertGreaterThan(
            try self.renderedHeight(markdown: "Here is the draft you asked for."),
            0)
    }

    func testQuotedResponseRendersTallerThanTheSameTextUnquoted() throws {
        let line = "Shipping beats planning, and the proof is in the transcript."
        let plain = try self.renderedHeight(markdown: "Here is the draft:\n\n\(line)")
        let quoted = try self.renderedHeight(markdown: "Here is the draft:\n\n> \(line)")

        // The quote rule plus its own copy affordance occupy real space; if the override
        // collapsed to nothing, these would match.
        XCTAssertGreaterThan(quoted, plain)
    }

    func testFencedCodeResponseRenders() throws {
        XCTAssertGreaterThan(
            try self.renderedHeight(markdown: "Run this:\n\n```sh\ngit push origin main\n```"),
            0)
    }

    func testQuoteContainingANestedFenceRenders() throws {
        XCTAssertGreaterThan(
            try self.renderedHeight(markdown: "> Ship it:\n>\n> ```sh\n> git push\n> ```"),
            0)
    }

    func testUserBubbleRenders() throws {
        let renderer = ImageRenderer(
            content: UserBubble(text: "Draft me a tweet about the transcript rewrite.")
                .frame(width: self.width))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.height, 0)
    }
}
