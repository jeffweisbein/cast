#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Cast

private final class MarkedComposerTextView: NSTextView {
    override func hasMarkedText() -> Bool { true }
}
@MainActor final class ComposerKeyboardTests: XCTestCase {
    func testReturnCommitsThroughNativeDelegate() {
        var sends = 0
        let field = ComposerNSTextView(text: .constant("question"), onEditingChange: { _ in },
            onCommit: { sends += 1 }, onMeasuredHeightChange: { _ in })
        XCTAssertTrue(field.makeCoordinator().textView(NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(sends, 1)
    }
    func testMarkedTextConfirmationIsLeftToInputMethod() {
        var sends = 0
        let field = ComposerNSTextView(text: .constant("composition"), onEditingChange: { _ in },
            onCommit: { sends += 1 }, onMeasuredHeightChange: { _ in })
        XCTAssertFalse(field.makeCoordinator().textView(MarkedComposerTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(sends, 0)
    }
    func testBusyEditorCannotCommit() {
        var sends = 0
        let field = ComposerNSTextView(text: .constant("question"), onEditingChange: { _ in },
            onCommit: { sends += 1 }, onMeasuredHeightChange: { _ in }, isEditable: false)
        XCTAssertTrue(field.makeCoordinator().textView(NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(sends, 0)
    }
    func testExplicitLineBreakDoesNotSend() {
        var sends = 0
        let field = ComposerNSTextView(text: .constant("question"), onEditingChange: { _ in },
            onCommit: { sends += 1 }, onMeasuredHeightChange: { _ in })
        XCTAssertTrue(field.makeCoordinator().textView(NSTextView(), doCommandBy: #selector(NSResponder.insertLineBreak(_:))))
        XCTAssertEqual(sends, 0)
    }
}
#endif
