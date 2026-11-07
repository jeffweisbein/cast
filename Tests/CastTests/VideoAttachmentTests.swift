import AVFoundation
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Cast

final class VideoAttachmentTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/video-upload.mp4")
    }

    func testSmallVideoPreservesMovieAndAudioBytesInRPC() async throws {
        let input = try Data(contentsOf: fixture)
        let attachment = try await AttachmentProcessor.prepareForSending(url: fixture)
        XCTAssertEqual(attachment.mimeType, "video/mp4")
        XCTAssertEqual(attachment.type, "file") // Existing gateway file transport, not an image block.
        XCTAssertEqual(attachment.data, input)
        XCTAssertEqual(Data(base64Encoded: attachment.rpcValue["content"] as! String), input)
        XCTAssertNoThrow(try AttachmentProcessor.validateFrame(message: "See this clip", attachments: [attachment]))
        let tracks = try await AVURLAsset(url: fixture).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
    }

    func testLargeVideoExportsBoundedPlayableCopyWithAudioWithoutChangingSource() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Screen Recording.mp4")
        var padded = try Data(contentsOf: fixture)
        padded.append(Data(count: AttachmentProcessor.maxFileBytes + 1))
        try padded.write(to: source)
        // Replays the existing synchronous path's size rejection before checking the new path.
        XCTAssertThrowsError(try AttachmentProcessor.prepare(url: source))
        let attachment = try await AttachmentProcessor.prepareForSending(url: source)
        XCTAssertEqual(attachment.mimeType, "video/mp4")
        XCTAssertEqual(attachment.fileName, "Screen Recording.mp4")
        XCTAssertLessThanOrEqual(attachment.byteCount, AttachmentProcessor.maxFileBytes)
        XCTAssertEqual(try Data(contentsOf: source), padded)
        let output = dir.appendingPathComponent("export.mp4")
        try attachment.data.write(to: output)
        let asset = AVURLAsset(url: output)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(audio.count, 1)
        XCTAssertGreaterThan(duration.seconds, 0.9)
        XCTAssertNoThrow(try AttachmentProcessor.validateFrame(message: "", attachments: [attachment]))
    }

    func testInvalidMovieIsRejectedRatherThanSendingThumbnailOrGarbage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try await AttachmentProcessor.prepareForSending(url: url); XCTFail("invalid movie accepted") }
        catch { }
    }

    func testCancelledImportProducesNoAttachment() async {
        let task = Task { () throws -> PreparedAttachment in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VideoAttachments.prepare(url: fixture)
        }
        do { _ = try await task.value; XCTFail("cancelled import accepted") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation: \(error)") }
    }

    func testMovieTypesDoNotTreatPhotosAsVideos() {
        XCTAssertTrue(VideoAttachments.isVideo(.quickTimeMovie))
        XCTAssertTrue(VideoAttachments.isVideo(.mpeg4Movie))
        XCTAssertFalse(VideoAttachments.isVideo(.jpeg))
        XCTAssertFalse(VideoAttachments.isVideo(.pdf))
    }
}
