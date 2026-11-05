import Foundation
import XCTest
@testable import Cast

final class LibraryScannerTests: XCTestCase {
    private static func message(_ text: String, role: String = "assistant", ts: Double, mediaPaths: [String] = [], mediaTypes: [String] = []) -> ChatMessage {
        ChatMessage(
            role: role,
            blocks: [ChatContentBlock(type: "text", text: text, thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: ts,
            mediaPaths: mediaPaths,
            mediaTypes: mediaTypes)
    }

    func testMediaScanIsNewestFirstAndDeduped() {
        let messages = [
            Self.message("first", role: "user", ts: 1000, mediaPaths: ["/m/a.jpg"], mediaTypes: ["image/jpeg"]),
            Self.message("again", role: "user", ts: 2000, mediaPaths: ["/m/a.jpg"], mediaTypes: ["image/jpeg"]),
            Self.message("video", role: "user", ts: 3000, mediaPaths: ["/m/b.mov"], mediaTypes: ["video/quicktime"]),
            Self.message("doc", role: "user", ts: 4000, mediaPaths: ["/m/c.pdf"], mediaTypes: ["application/pdf"]),
        ]
        let media = LibraryScanner.media(in: messages)
        XCTAssertEqual(media.map(\.id), ["/m/b.mov", "/m/a.jpg"])
        XCTAssertTrue(media[0].isVideo)
        XCTAssertTrue(media[1].isImage)
    }

    func testMediaKindFallsBackToPathExtensionWhenMimeTypeIsMissing() {
        let message = Self.message(
            "attachments",
            ts: 1000,
            mediaPaths: ["file:///tmp/a%20photo.HEIC", "/gateway/clip.MOV"])
        let media = LibraryScanner.media(in: [message])
        XCTAssertEqual(media.count, 2)
        XCTAssertTrue(media.contains(where: { $0.isImage && $0.fileName == "a photo.HEIC" }))
        XCTAssertTrue(media.contains(where: { $0.isVideo && $0.fileName == "clip.MOV" }))
    }

    func testAudioAttachmentsClassifyAsAudioForSentAndSniffedMimeTypes() {
        // Cast sends audio/mp4; the gateway echoes the sniffed audio/x-m4a. Both must
        // classify as audio, and a bare .m4a path must fall back via its extension.
        let message = Self.message(
            "voice",
            role: "user",
            ts: 1000,
            mediaPaths: ["/m/sent.m4a", "/m/echoed.m4a", "/m/bare.m4a"],
            mediaTypes: ["audio/mp4", "audio/x-m4a", ""])
        let items = LibraryScanner.mediaItems(of: message)
        XCTAssertEqual(items.count, 3)
        for item in items {
            XCTAssertTrue(item.isAudio, "\(item.id) should be audio")
            XCTAssertFalse(item.isImage)
            XCTAssertFalse(item.isVideo)
        }
    }

    func testAudioStaysOutOfLibraryMediaGridAndVideosAreNotAudio() {
        let messages = [
            Self.message("voice", role: "user", ts: 1000, mediaPaths: ["/m/v.m4a"], mediaTypes: ["audio/x-m4a"]),
            Self.message("clip", role: "user", ts: 2000, mediaPaths: ["/m/b.mov"], mediaTypes: ["video/quicktime"]),
        ]
        let media = LibraryScanner.media(in: messages)
        XCTAssertEqual(media.map(\.id), ["/m/b.mov"])
        XCTAssertFalse(media[0].isAudio)
    }

    func testMediaFileURLAndTildePathsResolveWithoutDoubleEncoding() {
        XCTAssertEqual(
            MediaThumbnailLoader.resolvedFileURL(for: "file:///tmp/a%20photo.jpg").path,
            "/tmp/a photo.jpg")
        XCTAssertTrue(MediaThumbnailLoader.resolvedFileURL(for: "~/photo.jpg").path.hasSuffix("/photo.jpg"))
        XCTAssertFalse(MediaThumbnailLoader.resolvedFileURL(for: "~/photo.jpg").path.contains("~"))
    }

    func testLocalEchoBytesYieldMediaItemsUntilPathsArrive() {
        let local = ChatMessage(role: "user", blocks: [], timestamp: 1000, localImageData: [Data([1, 2, 3])])
        XCTAssertEqual(LibraryScanner.mediaItems(of: local).count, 1)
        XCTAssertNotNil(LibraryScanner.mediaItems(of: local)[0].localData)

        let echoed = ChatMessage(role: "user", blocks: [], timestamp: 1000, mediaPaths: ["/m/a.jpg"], mediaTypes: ["image/jpeg"], localImageData: [Data([1, 2, 3])])
        let items = LibraryScanner.mediaItems(of: echoed)
        XCTAssertEqual(items.map(\.path), ["/m/a.jpg"])
        XCTAssertEqual(items.first?.localData, Data([1, 2, 3]))
    }

    func testLinksDedupeKeepNewestAndIgnoreNonHTTP() {
        let messages = [
            Self.message("see https://runpr.ai/pricing today", ts: 1000),
            Self.message("mail me at jeff@example.com or ftp://old.example.com", ts: 2000),
            Self.message("again https://runpr.ai/pricing and https://cackles.club", ts: 3000),
        ]
        let links = LibraryScanner.links(in: messages)
        XCTAssertEqual(links.map { $0.url.absoluteString }, ["https://runpr.ai/pricing", "https://cackles.club"])
        XCTAssertEqual(links[0].date, Date(timeIntervalSince1970: 3))
    }

    func testLinksCanonicalizeFragmentsDefaultPortsAndHostCase() {
        let messages = [
            Self.message("https://EXAMPLE.com:443/post#first", ts: 1000),
            Self.message("https://example.com/post#second", ts: 2000),
        ]
        let links = LibraryScanner.links(in: messages)
        XCTAssertEqual(links.map { $0.url.absoluteString }, ["https://example.com/post#second"])
        XCTAssertEqual(links.first?.date, Date(timeIntervalSince1970: 2))
    }

    func testLinksSkipToolResultRows() {
        let toolRow = ChatMessage(
            role: "toolResult",
            blocks: [ChatContentBlock(type: "text", text: "https://internal.example.com/logs", thinking: nil, name: nil, mimeType: nil, fileName: nil)],
            timestamp: 1000)
        XCTAssertTrue(LibraryScanner.links(in: [toolRow]).isEmpty)
    }

    func testMessageLevelMediaFieldsDecodeFromHistoryShape() throws {
        // Exact shape returned by chat.history for an attachment message (verified live).
        let json = """
        {"role":"user","content":"Summarize the attached image.","timestamp":1784667048044,
         "MediaPath":"/Users/x/.openclaw/media/inbound/a.jpg",
         "MediaPaths":["/Users/x/.openclaw/media/inbound/a.jpg"],
         "MediaType":"image/jpeg","MediaTypes":["image/jpeg"]}
        """
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.mediaPaths, ["/Users/x/.openclaw/media/inbound/a.jpg"])
        XCTAssertEqual(message.mediaTypes, ["image/jpeg"])
        XCTAssertEqual(message.text, "Summarize the attached image.")

        // Cache round-trip keeps media refs so the library works from cached transcripts.
        let reencoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(reencoded.mediaPaths, message.mediaPaths)
        XCTAssertEqual(reencoded.mediaTypes, message.mediaTypes)
    }

    func testToolCallArgumentsDecodeAndMalformedBlockDegradesGracefully() throws {
        let json = """
        {"role":"assistant","timestamp":1,"content":[
          {"type":"toolCall","id":"exec-1","name":"bash","arguments":{"command":"ls -la","cwd":"/tmp"}},
          {"type":"toolCall","name":"weird","arguments":"not-an-object"},
          "bare string block"
        ]}
        """
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.blocks.count, 3)
        XCTAssertEqual(TranscriptBuilder.toolSummary(name: "bash", arguments: message.blocks[0].arguments), "ls -la")
        XCTAssertNil(TranscriptBuilder.toolSummary(name: "weird", arguments: message.blocks[1].arguments))
        XCTAssertEqual(message.blocks[2].text, "bare string block")
    }

    func testMergePreservesLocalImageBytesWhenEchoArrives() {
        let bytes = Data([9, 9, 9])
        let local = ChatMessage(id: "local-1", role: "user", blocks: [], timestamp: 1, localImageData: [bytes])
        var pending = [PendingEcho(id: "local-1", sentText: "")]
        let echo = ChatMessage(id: "server-1", role: "user", blocks: [], timestamp: 2, mediaPaths: ["/gw/host/a.jpg"], mediaTypes: ["image/jpeg"])
        let merged = ChatStore.mergedMessages([local], incoming: echo, pendingEchoes: &pending)
        XCTAssertEqual(merged.map(\.id), ["server-1"])
        XCTAssertEqual(merged[0].localImageData, [bytes])
        XCTAssertEqual(merged[0].mediaPaths, ["/gw/host/a.jpg"])
    }
}
