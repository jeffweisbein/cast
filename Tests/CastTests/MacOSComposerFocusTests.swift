#if os(macOS)
import AppKit
import XCTest
@testable import Cast

@MainActor
private final class ComposerFocusWindow: NSWindow {
    var simulatedKey = true
    override var isKeyWindow: Bool { simulatedKey }
}

@MainActor
final class MacOSComposerFocusTests: XCTestCase {
    private func fixture() -> (ComposerFocusWindow, MacOSComposerTextView) {
        let window = ComposerFocusWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let composer = MacOSComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 50))
        composer.applicationIsActive = { true }
        window.contentView?.addSubview(composer)
        return (window, composer)
    }

    func testRestoresInsertionPointWithoutChangingDraftOrSelection() {
        let (window, composer) = fixture()
        defer { window.close() }
        composer.string = "A draft in progress"
        composer.setSelectedRange(NSRange(location: 3, length: 0))
        window.makeFirstResponder(window.contentView)
        XCTAssertTrue(composer.restoreComposerFocus())
        XCTAssertTrue(window.firstResponder === composer)
        XCTAssertEqual(composer.string, "A draft in progress")
        XCTAssertEqual(composer.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testLeavesAnotherEditorAndSelectedTranscriptTextAlone() {
        let (window, composer) = fixture()
        defer { window.close() }
        let other = NSTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 50))
        window.contentView?.addSubview(other)
        other.string = "Search or rename"
        window.makeFirstResponder(other)
        XCTAssertFalse(composer.restoreComposerFocus())
        XCTAssertTrue(window.firstResponder === other)
        other.isEditable = false
        other.setSelectedRange(NSRange(location: 0, length: 6))
        XCTAssertFalse(composer.restoreComposerFocus())
        XCTAssertTrue(window.firstResponder === other)
    }

    func testDoesNotFocusBackgroundWindowHiddenComposerOrSheet() {
        let (window, composer) = fixture()
        defer { window.close() }
        window.makeFirstResponder(window.contentView)
        composer.applicationIsActive = { false }
        XCTAssertFalse(composer.restoreComposerFocus())
        composer.applicationIsActive = { true }
        window.simulatedKey = false
        XCTAssertFalse(composer.restoreComposerFocus())
        window.simulatedKey = true
        composer.isHidden = true
        XCTAssertFalse(composer.restoreComposerFocus())
        composer.isHidden = false
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        XCTAssertFalse(composer.restoreComposerFocus())
        window.endSheet(sheet)
        sheet.close()
    }

    func testKeyWindowNotificationRestoresFocusAndDetachedViewIgnoresIt() async {
        let (window, composer) = fixture()
        defer { window.close() }
        window.makeFirstResponder(window.contentView)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let focused = expectation(description: "Activation processed after the click")
        DispatchQueue.main.async { focused.fulfill() }
        await fulfillment(of: [focused], timeout: 2)
        XCTAssertTrue(window.firstResponder === composer)

        window.makeFirstResponder(window.contentView)
        composer.removeFromSuperview()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let detached = expectation(description: "Detached activation drained")
        DispatchQueue.main.async { detached.fulfill() }
        await fulfillment(of: [detached], timeout: 2)
        XCTAssertFalse(window.firstResponder === composer)
    }

    func testActivationClickIntoAnotherEditorWinsOverDeferredComposerFocus() async {
        let (window, composer) = fixture()
        defer { window.close() }
        let search = NSTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 50))
        window.contentView?.addSubview(search)
        window.makeFirstResponder(window.contentView)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        // The activating mouse-down reaches its intended field before the queued
        // default-focus request. It must not get redirected back to chat.
        window.makeFirstResponder(search)
        let settled = expectation(description: "Activation click settled")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertTrue(window.firstResponder === search)
        XCTAssertFalse(window.firstResponder === composer)
    }
}
#endif
