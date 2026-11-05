import Foundation
import XCTest
@testable import Cast

final class MainThreadWatchdogTests: XCTestCase {
    func testNormalHeartbeatsDoNotCreateStallRecords() {
        var tracker = MainThreadStallTracker()
        for duration in [0.0, 100, 499] {
            XCTAssertNil(tracker.check(durationMilliseconds: duration))
            XCTAssertNil(tracker.recover(durationMilliseconds: duration))
        }
    }

    func testWarningHangAndRecoveryRetainDurationAndOperationContextOnDisk() throws {
        var tracker = MainThreadStallTracker()
        let warning = try XCTUnwrap(tracker.check(durationMilliseconds: 500))
        XCTAssertNil(tracker.check(durationMilliseconds: 2_999))
        let hang = try XCTUnwrap(tracker.check(durationMilliseconds: 3_000))
        XCTAssertNil(tracker.check(durationMilliseconds: 9_000))
        let recovery = try XCTUnwrap(tracker.recover(durationMilliseconds: 9_123))
        XCTAssertNil(tracker.recover(durationMilliseconds: 9_124))
        XCTAssertEqual(warning.stallID, hang.stallID)
        XCTAssertEqual(hang.stallID, recovery.stallID)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastWatchdogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("stalls.json")
        let buffer = MainThreadStallRingBuffer(fileURL: fileURL)
        let runID = UUID()
        _ = buffer.beginRun(runID)
        let operation = CastPerformanceOperationRecord(
            operationID: UUID(), timestamp: Date(), operation: "transcriptCache",
            phase: "begin", durationMilliseconds: nil, metadata: "message_count=100")
        for observation in [warning, hang, recovery] {
            buffer.append(observation.record(runID: runID, recentOperations: [operation]))
        }
        let persisted = MainThreadStallRingBuffer(fileURL: fileURL).snapshot().records
        XCTAssertEqual(persisted.map(\.phase), [.warning, .hang, .recovered])
        XCTAssertEqual(persisted.map(\.observedDurationMilliseconds), [500, 3_000, 9_123])
        XCTAssertTrue(persisted.allSatisfy { $0.runID == runID && $0.stallID == warning.stallID })
        XCTAssertTrue(persisted.allSatisfy { $0.recentOperations.first?.operationID == operation.operationID })
        XCTAssertTrue(persisted.allSatisfy {
            $0.mainThreadBacktrace.first?.hasPrefix("Not captured: in-process thread suspension is unsafe") == true
        })
    }

    func testRecoveryAllowsAnotherStallWithANewIdentity() throws {
        var tracker = MainThreadStallTracker()
        let first = try XCTUnwrap(tracker.check(durationMilliseconds: 700))
        let recovery = try XCTUnwrap(tracker.recover(durationMilliseconds: 800))
        XCTAssertEqual(recovery.stallID, first.stallID)
        let next = try XCTUnwrap(tracker.check(durationMilliseconds: 600))
        XCTAssertEqual(next.phase, .warning)
        XCTAssertNotEqual(first.stallID, next.stallID)
        XCTAssertEqual(tracker.check(durationMilliseconds: 3_200)?.phase, .hang)
    }

    func testFirstDelayedTimerCheckStillRecordsWarningBeforeHang() throws {
        var tracker = MainThreadStallTracker()
        XCTAssertEqual(tracker.check(durationMilliseconds: 3_500)?.phase, .warning)
        XCTAssertEqual(tracker.check(durationMilliseconds: 3_600)?.phase, .hang)
        XCTAssertNil(tracker.check(durationMilliseconds: 3_700))
        XCTAssertEqual(tracker.recover(durationMilliseconds: 3_800)?.phase, .recovered)
    }
}
