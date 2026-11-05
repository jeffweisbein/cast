import XCTest

@testable import Cast

final class AssistantMarkdownSegmentsTests: XCTestCase {
    func testPlainMarkdownStaysASingleSegment() {
        let segments = AssistantMarkdownParser.segments("Just **prose** with no tags.")

        XCTAssertEqual(segments, [.markdown("Just **prose** with no tags.")])
    }

    func testDisclosureIsLiftedOutOfSurroundingProse() {
        let text = """
            The answer.

            <details>
            <summary>Loose ends</summary>

            Background nobody has to read.
            </details>

            Trailing note.
            """

        XCTAssertEqual(
            AssistantMarkdownParser.segments(text),
            [
                .markdown("The answer."),
                .disclosure(
                    summary: "Loose ends",
                    body: "Background nobody has to read.",
                    isComplete: true),
                .markdown("Trailing note."),
            ])
    }

    func testMultipleDisclosuresKeepTheirOrder() {
        let text = "<details><summary>One</summary>First</details>"
            + "middle"
            + "<details><summary>Two</summary>Second</details>"

        XCTAssertEqual(
            AssistantMarkdownParser.segments(text),
            [
                .disclosure(summary: "One", body: "First", isComplete: true),
                .markdown("middle"),
                .disclosure(summary: "Two", body: "Second", isComplete: true),
            ])
    }

    func testAttributesOnTheTagAreTolerated() {
        let segments = AssistantMarkdownParser.segments(
            #"<details open class="x"><summary id="s">Label</summary>Body</details>"#)

        XCTAssertEqual(
            segments, [.disclosure(summary: "Label", body: "Body", isComplete: true)])
    }

    func testMissingSummaryFallsBackToALabel() {
        let segments = AssistantMarkdownParser.segments("<details>Body only</details>")

        XCTAssertEqual(
            segments,
            [
                .disclosure(
                    summary: AssistantMarkdownParser.fallbackSummary,
                    body: "Body only",
                    isComplete: true)
            ])
    }

    func testStreamingDisclosureNeverLeaksRawTags() {
        let segments = AssistantMarkdownParser.segments(
            "Answer.\n\n<details>\n<summary>Detail</summary>\n\nHalf a bo")

        XCTAssertEqual(
            segments,
            [
                .markdown("Answer."),
                .disclosure(summary: "Detail", body: "Half a bo", isComplete: false),
            ])
    }

    func testStreamingSummaryHoldsTheFallbackLabel() {
        let segments = AssistantMarkdownParser.segments("<details>\n<summary>Half a lab")

        XCTAssertEqual(
            segments,
            [
                .disclosure(
                    summary: AssistantMarkdownParser.fallbackSummary,
                    body: "<summary>Half a lab",
                    isComplete: false)
            ])
    }

    func testCopyTextIncludesDisclosureContent() {
        let content = AssistantResponseContent(
            markdown: "Visible answer.\n\n<details><summary>More</summary>Hidden depth.</details>")

        let copied = content.copyText
        XCTAssertTrue(copied.contains("Visible answer."))
        XCTAssertTrue(copied.contains("More"))
        XCTAssertTrue(copied.contains("Hidden depth."))
        XCTAssertFalse(copied.contains("<details>"))
        XCTAssertFalse(copied.contains("<summary>"))
    }

    func testDisclosureBodyIsCollapsedByDefaultOnceComplete() {
        let content = AssistantResponseContent(
            markdown: "<details><summary>More</summary>Depth.</details>")

        guard case let .disclosure(_, _, startsExpanded)? = content.blocks.first else {
            return XCTFail("expected a disclosure block")
        }
        XCTAssertFalse(startsExpanded)
    }
}
