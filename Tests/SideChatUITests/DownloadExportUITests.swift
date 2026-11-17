import XCTest

final class DownloadExportUITests: XCTestCase {
    func testChatDocumentSaveAsOpensNativeExporterAndCancelPreservesSource() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-fixture", "--download-fixture"]
        app.launch()
        #if os(macOS)
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        #endif
        let save = app.buttons["download.save-copy"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(save.isHittable)
        capture("document-downloaded", app)
        press(save)
        #if os(macOS)
        let panel = app.sheets["save-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
        let cancel = panel.buttons["CancelButton"]
        XCTAssertTrue(cancel.exists, app.debugDescription)
        XCTAssertTrue(panel.buttons["OKButton"].exists, "Expected native Export action")
        capture("native-save-copy-panel", app)
        press(cancel)
        #else
        // iOS 26's Files exporter can show Browse + Save without a Cancel button.
        // Exercise a real export, rather than assume Mac-style panel controls.
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 10), app.debugDescription)
        let nativeSave = app.buttons["Save"].firstMatch
        XCTAssertTrue(nativeSave.waitForExistence(timeout: 5), app.debugDescription)
        // Add a unique token wherever the native picker places its insertion point.
        // No selection gesture or previously exported fixture is required.
        press(filename)
        filename.typeText("-" + UUID().uuidString)
        XCTAssertTrue(nativeSave.isEnabled, "Choose a writable Files destination in the simulator fixture")
        capture("native-save-copy-panel", app)
        press(nativeSave)
        XCTAssertTrue(app.staticTexts["Saved a copy to your selected folder."].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(filename.exists, "Native exporter must dismiss after saving")
        #endif
        let returnedToDocument = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in save.exists && save.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returnedToDocument], timeout: 10), .completed, app.debugDescription)
        press(app.buttons["download-fixture.verify-source"])
        let sourceStatus = app.staticTexts["download-fixture.source-status"]
        XCTAssertEqual((sourceStatus.value as? String) ?? sourceStatus.label, "Source intact")
        capture("save-action-source-intact", app)
    }
    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        #if os(macOS)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        #endif
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
