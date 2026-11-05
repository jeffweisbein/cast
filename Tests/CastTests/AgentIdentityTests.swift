import Foundation
import XCTest
@testable import Cast

final class AgentIdentityTests: XCTestCase {
    func testRelativeAvatarResolvesAgainstGatewayOnly() throws {
        let gateway = try XCTUnwrap(URL(string: "wss://gateway.example.test/ws"))
        XCTAssertEqual(
            AgentAvatarSource.resolve("/avatar/main", gatewayURL: gateway),
            .remote(try XCTUnwrap(URL(string: "https://gateway.example.test/avatar/main"))))
    }

    func testUnsafeAvatarSchemesAreRejected() throws {
        let gateway = try XCTUnwrap(URL(string: "wss://gateway.example.test/ws"))
        XCTAssertNil(AgentAvatarSource.resolve("file:///etc/passwd", gatewayURL: gateway))
        XCTAssertNil(AgentAvatarSource.resolve("javascript:alert(1)", gatewayURL: gateway))
        XCTAssertNil(AgentAvatarSource.resolve("http://example.test/avatar.png", gatewayURL: gateway))
    }

    func testDataAvatarHonorsSizeCeiling() throws {
        let gateway = try XCTUnwrap(URL(string: "ws://localhost:18789"))
        let small = Data("image".utf8).base64EncodedString()
        XCTAssertEqual(
            AgentAvatarSource.resolve("data:image/png;base64,\(small)", gatewayURL: gateway),
            .data(Data("image".utf8)))
        let oversized = Data(count: AgentAvatarSource.maximumBytes + 1).base64EncodedString()
        XCTAssertNil(AgentAvatarSource.resolve("data:image/png;base64,\(oversized)", gatewayURL: gateway))
    }

    func testFallbackInitialsUseAtMostTwoWords() {
        XCTAssertEqual(AgentIdentityFallback.initials(from: "Franklin Delano Roosevelt"), "FD")
        XCTAssertNil(AgentIdentityFallback.initials(from: "  "))
    }

    func testIdentityDecodeIsLenientAndKeepsAvatarStatus() throws {
        let data = Data(#"{"agentId":"main","name":" Fubz ","emoji":"🤪","avatar":42,"avatarStatus":"resolved","avatarReason":"workspace"}"#.utf8)
        let identity = try JSONDecoder().decode(AgentIdentity.self, from: data)
        XCTAssertEqual(identity.agentId, "main")
        XCTAssertEqual(identity.name, "Fubz")
        XCTAssertEqual(identity.emoji, "🤪")
        XCTAssertNil(identity.avatar)
        XCTAssertEqual(identity.avatarStatus, "resolved")
        XCTAssertEqual(identity.avatarReason, "workspace")
    }

    func testFallbackPrefersIdentityInitialsThenEmojiThenLocalName() {
        XCTAssertEqual(
            AgentIdentityFallback.choice(identityName: "Fubz Bot", emoji: "🤪", fallbackName: "Workspace"),
            .initials("FB"))
        XCTAssertEqual(
            AgentIdentityFallback.choice(identityName: nil, emoji: "🤪", fallbackName: "Workspace"),
            .emoji("🤪"))
        XCTAssertEqual(
            AgentIdentityFallback.choice(identityName: nil, emoji: nil, fallbackName: "Workspace"),
            .initials("W"))
    }

    func testAvatarCacheKeyIsWorkspaceAndAgentScoped() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/avatar.png"))
        let first = AgentAvatarCacheKey(workspaceID: "one", agentID: "main", url: url)
        XCTAssertNotEqual(first, AgentAvatarCacheKey(workspaceID: "two", agentID: "main", url: url))
        XCTAssertNotEqual(first, AgentAvatarCacheKey(workspaceID: "one", agentID: "other", url: url))
    }

    func testAvatarCacheHitsStayScopedAndEvictOldest() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/avatar.png"))
        let first = AgentAvatarCacheKey(workspaceID: "one", agentID: "main", url: url)
        let second = AgentAvatarCacheKey(workspaceID: "two", agentID: "main", url: url)
        let third = AgentAvatarCacheKey(workspaceID: "three", agentID: "main", url: url)
        let cache = AgentAvatarDataCache(capacity: 2)
        await cache.insert(Data("one".utf8), for: first)
        await cache.insert(Data("two".utf8), for: second)

        let firstHit = await cache.cachedData(for: first)
        let secondHit = await cache.cachedData(for: second)
        XCTAssertEqual(firstHit, Data("one".utf8))
        XCTAssertEqual(secondHit, Data("two".utf8))

        // Touching first makes second the oldest.
        _ = await cache.cachedData(for: first)
        await cache.insert(Data("three".utf8), for: third)
        let evicted = await cache.cachedData(for: second)
        let retained = await cache.cachedData(for: first)
        XCTAssertNil(evicted)
        XCTAssertEqual(retained, Data("one".utf8))
    }
}
