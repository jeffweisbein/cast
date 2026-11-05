#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Cast

/// Fictional, offline rendering only: no Gateway client is started and no app
/// credentials or installed customer process are accessed by this fixture.
@MainActor
final class QuestionCardRenderingTests: XCTestCase {
    func testProductionCardsRenderPendingFailureAndTerminalStates() throws {
        let store = ChatStore(profile: WorkspaceProfile(id: "question-render-" + UUID().uuidString,
            name: "Offline question fixture", gatewayURL: URL(string: "ws://127.0.0.1:1")!, accent: "orange"),
            transcriptCacheRoot: URL(fileURLWithPath: "/__cast_question_fixture_no_io__"))
        let variants = ["single", "multi-other", "text", "submitting", "unconfirmed", "answered", "cancelled", "expired"]
        for variant in variants {
            let request = try QuestionRequestTests.fixture(id: variant, multi: variant == "multi-other",
                options: variant == "text" ? [] : ["Prepare a draft (Recommended)", "Research a little more"],
                expires: variant == "expired" ? 1 : nil)
            store.questionInbox.receive(request)
            if variant == "multi-other" || variant == "unconfirmed" || variant == "submitting" {
                var draft = QuestionDraft()
                draft.selections["choice"] = ["Prepare a draft (Recommended)"]
                if variant == "multi-other" {
                    draft.usingOther.insert("choice")
                    draft.text["choice"] = "Include a source for every claim."
                }
                store.questionInbox.updateDraft(id: variant, draft: draft)
            }
            if variant == "submitting" { _ = store.questionInbox.begin(id: variant) }
            if variant == "unconfirmed" { _ = store.questionInbox.begin(id: variant); store.questionInbox.failed(id: variant) }
            if variant == "answered" || variant == "cancelled" { store.questionInbox.resolve(id: variant, status: variant) }
            let view = QuestionCardView(store: store, requestID: variant, showsConversation: true)
                .padding(20).frame(width: 580).background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            let fitting = hosting.fittingSize
            hosting.frame = CGRect(origin: .zero, size: CGSize(width: 580, height: max(300, fitting.height)))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 1000)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "question-card-" + variant
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
#endif
