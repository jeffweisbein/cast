// Cast — pasteboard payloads for the transcript's per-block copy affordances.
//
// Cast deliberately owns no markdown scanner: `CopyPayload.quote` is handed the same
// `MarkdownContent` MarkdownUI built while rendering the block, so which text belongs to a
// quote is cmark's decision, not ours. These tests therefore pin cmark's block boundaries
// for the inputs that are easy to get wrong by hand — nested fences, unterminated fences,
// lazy continuation — so a MarkdownUI upgrade that moves them fails here instead of
// silently putting the wrong text on Jeff's pasteboard.
//
// A theme block style receives a `MarkdownContent` holding exactly one block, which is
// what `MarkdownContent("> …")` produces for a document that is only that block, so these
// fixtures exercise the shipping code path rather than an approximation of it.
import MarkdownUI
import XCTest

@testable import Cast

final class CopyPayloadTests: XCTestCase {
    func testResponseCopyPayloadIsNotResolvedWhileTheButtonRenders() {
        let content = AssistantResponseContent(markdown: "A **rendered** response.")
        var resolutions = 0
        let button = CopyBlockButton(textProvider: {
            resolutions += 1
            return content.copyText
        })

        _ = button.body
        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(button.resolvedText(), "A rendered response.")
        XCTAssertEqual(resolutions, 1)
    }

    // MARK: - Normalization

    func testNormalizedDropsSurroundingBlankLinesButKeepsInteriorOnes() {
        let raw = "\n\nFirst paragraph.\n\nSecond paragraph.\n\n"

        XCTAssertEqual(
            CopyPayload.normalized(raw),
            "First paragraph.\n\nSecond paragraph.")
    }

    func testNormalizedKeepsLeadingIndentationOfContentLines() {
        let raw = "\n    indented = true\n        deeper = true\n"

        XCTAssertEqual(
            CopyPayload.normalized(raw),
            "    indented = true\n        deeper = true")
    }

    func testNormalizedDropsWhitespaceOnlyEdgeLines() {
        XCTAssertEqual(CopyPayload.normalized("   \nkeep\n\t\n"), "keep")
    }

    func testNormalizedLeavesAlreadyCleanTextUntouched() {
        XCTAssertEqual(CopyPayload.normalized("exactly this"), "exactly this")
    }

    func testNormalizedOfWhitespaceOnlyInputIsEmpty() {
        XCTAssertEqual(CopyPayload.normalized("\n \n\t\n"), "")
    }

    // MARK: - Quoted blocks

    func testQuoteDropsTheMarkerAndTheTrailingNewline() {
        let quote = MarkdownContent("> Thanks for the intro — happy to take that call Thursday.")

        XCTAssertEqual(
            CopyPayload.quote(quote),
            "Thanks for the intro — happy to take that call Thursday.")
    }

    func testQuoteKeepsTheBlankLineBetweenQuotedParagraphs() {
        // A drafted email is the motivating case: paragraph breaks have to survive the trip
        // to the pasteboard or the copy is unusable.
        let quote = MarkdownContent("> Hi Dana,\n>\n> Following up on the piece from last week.\n>\n> Jeff")

        XCTAssertEqual(
            CopyPayload.quote(quote),
            "Hi Dana,\n\nFollowing up on the piece from last week.\n\nJeff")
    }

    func testQuoteAbsorbsLazyContinuationLines() {
        // cmark folds an unmarked line after a quoted paragraph into the quote. The copy has
        // to include it, because that is what the reader sees inside the quote rule.
        let quote = MarkdownContent("> First half of the sentence\nand the unmarked second half.")

        XCTAssertEqual(
            CopyPayload.quote(quote),
            "First half of the sentence\nand the unmarked second half.")
    }

    func testQuoteContainingANestedFenceKeepsTheCodeAndDropsTheFence() {
        let quote = MarkdownContent("> Ship it with:\n>\n> ```sh\n> git push origin main\n> ```")
        let payload = CopyPayload.quote(quote)

        XCTAssertTrue(payload.contains("git push origin main"), payload)
        XCTAssertFalse(payload.contains("```"), payload)
        XCTAssertFalse(payload.contains(">"), payload)
    }

    func testQuoteRendersInlineMarkupAsPlainTextAndDropsLinkTargets() {
        let quote = MarkdownContent("> Read **the brief** at [our site](https://example.com/brief).")
        let payload = CopyPayload.quote(quote)

        XCTAssertEqual(payload, "Read the brief at our site.")
        XCTAssertFalse(payload.contains("https://example.com/brief"), payload)
    }

    func testNestedQuotesFlattenIntoOnePayload() {
        let quote = MarkdownContent("> Outer line\n>\n> > Inner line")
        let payload = CopyPayload.quote(quote)

        XCTAssertTrue(payload.contains("Outer line"), payload)
        XCTAssertTrue(payload.contains("Inner line"), payload)
        XCTAssertFalse(payload.contains(">"), payload)
    }

    func testQuotedTweetDraftSurvivesVerbatim() {
        let draft = "Shipping beats planning. We rewrote the transcript in a weekend and the "
            + "only thing that mattered was being able to copy the draft out of it."
        let quote = MarkdownContent("> \(draft)")

        XCTAssertEqual(CopyPayload.quote(quote), draft)
    }

    // MARK: - Code blocks

    func testCodeStripsTheTrailingBlankLinesAuthorsLeaveInsideAFence() {
        XCTAssertEqual(
            CopyPayload.code("let shipped = true\n\n"),
            "let shipped = true")
    }

    func testCodeKeepsInteriorBlankLinesAndIndentation() {
        let body = "func run() {\n\n    print(\"go\")\n}"

        XCTAssertEqual(CopyPayload.code(body), body)
    }

    // MARK: - Fence boundaries (cmark's decision, pinned here)

    func testUnterminatedFenceStillClosesAtTheEndOfTheMessage() {
        // Streaming responses land mid-fence constantly. cmark closes the block at EOF, so
        // the partial code is still a code block and still copyable.
        let content = MarkdownContent("Here it is:\n\n```swift\nlet partial = true")

        XCTAssertTrue(content.renderPlainText().contains("let partial = true"))
    }

    func testLongerFenceContainsAShorterOneWithoutClosingEarly() {
        // A fence only closes on a run at least as long as the one that opened it, so the
        // inner ``` belongs to the code, not to the boundary.
        let markdown = "````md\n```sh\nnested\n```\n````"
        let payload = CopyPayload.code(
            markdown
                .components(separatedBy: "\n")
                .dropFirst()
                .dropLast()
                .joined(separator: "\n"))

        XCTAssertEqual(payload, "```sh\nnested\n```")
        XCTAssertTrue(MarkdownContent(markdown).renderPlainText().contains("nested"))
    }

    func testMessageWithNoQuotableBlockRendersNothingQuoteLike() {
        // The "unchanged message" guarantee: plain prose produces no quote and no fence, so
        // no affordance is added to it.
        let content = MarkdownContent("Just a sentence with **emphasis** and nothing to lift.")

        XCTAssertEqual(
            CopyPayload.normalized(content.renderPlainText()),
            "Just a sentence with emphasis and nothing to lift.")
    }
}
