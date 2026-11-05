import Foundation
import UniformTypeIdentifiers
import XCTest

final class ShareExtensionActivationTests: XCTestCase {
    func testActivationRuleAcceptsScreenshotRepresentationsAndRejectsOpaqueData() throws {
        let predicate = try self.activationPredicate()

        XCTAssertTrue(self.evaluate(predicate, identifiers: [UTType.png.identifier]))
        XCTAssertTrue(self.evaluate(predicate, identifiers: [UTType.image.identifier]))
        XCTAssertTrue(self.evaluate(predicate, identifiers: ["com.apple.uikit.image"]))
        XCTAssertTrue(self.evaluate(predicate, identifiers: [UTType.pdf.identifier]))

        XCTAssertFalse(self.evaluate(predicate, identifiers: [UTType.data.identifier]))
        XCTAssertFalse(self.evaluate(
            predicate,
            identifiers: [UTType.png.identifier, UTType.data.identifier]))
    }

    func testActivationRuleUsesHostExtensionItemsKeyPath() throws {
        let predicate = try self.activationPredicate()
        XCTAssertFalse(
            predicate.predicateFormat.contains("$extensionItems"),
            "extensionItems is a host key path, not an NSPredicate substitution variable")
    }

    private func activationPredicate() throws -> NSPredicate {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repositoryRoot.appendingPathComponent("Support/CastShareExtension-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let extensionDictionary = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(
            extensionDictionary["NSExtensionAttributes"] as? [String: Any])
        let rule = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String)
        return NSPredicate(format: rule)
    }

    private func evaluate(_ predicate: NSPredicate, identifiers: [String]) -> Bool {
        let item = NSExtensionItem()
        item.attachments = identifiers.map {
            NSItemProvider(item: Data([0x01]) as NSData, typeIdentifier: $0)
        }
        return predicate.evaluate(with: ActivationInput(extensionItems: [item]))
    }
}

private final class ActivationInput: NSObject {
    @objc let extensionItems: [NSExtensionItem]

    init(extensionItems: [NSExtensionItem]) {
        self.extensionItems = extensionItems
    }
}
