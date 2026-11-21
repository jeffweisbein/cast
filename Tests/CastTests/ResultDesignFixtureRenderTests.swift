import AppKit
import SwiftUI
import XCTest
@testable import Cast

/// Renders the production result-design components with fictional offline data in an
/// AppKit window (so native controls draw) and writes PNGs for visual review. Assertions
/// cover non-empty intrinsic geometry; visual quality is judged from the images.
@MainActor
final class ResultDesignFixtureRenderTests: XCTestCase {
    private var outputDirectory: URL {
        let env = ProcessInfo.processInfo.environment["CAST_FIXTURE_OUTPUT"]
        let url = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("cast-result-design-fixtures")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func render<V: View>(_ view: V, width: CGFloat, name: String, dark: Bool) throws -> CGSize {
        let root = view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(dark ? Color(white: 0.11) : Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        XCTAssertGreaterThan(size.height, 40, "\(name) rendered no content")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: self.outputDirectory.appendingPathComponent("mac-\(name)-\(dark ? "dark" : "light").png"))
        window.contentView = nil
        return size
    }

    func testRenderResultDesignScenes() throws {
        for dark in [false, true] {
            _ = try self.render(ResultDesignFixtureView(scene: .sidebar), width: 300, name: "sidebar", dark: dark)
            _ = try self.render(ResultDesignFixtureView(scene: .chat), width: 520, name: "chat", dark: dark)
            _ = try self.render(ResultDesignFixtureView(scene: .review), width: 380, name: "review-files", dark: dark)
            _ = try self.render(ResultDesignFixtureView(scene: .progress), width: 380, name: "review-progress", dark: dark)
            _ = try self.render(ResultDesignFixtureView(scene: .details), width: 380, name: "review-details", dark: dark)
        }
        // A narrow card must wrap the evidence strip instead of clipping it.
        let narrow = try self.render(
            ChatResultCardContent(summary: ResultDesignFixture.summary, state: nil, openReview: {}).padding(8),
            width: 280, name: "card-narrow", dark: true)
        let wide = try self.render(
            ChatResultCardContent(summary: ResultDesignFixture.summary, state: nil, openReview: {}).padding(8),
            width: 560, name: "card-wide", dark: true)
        XCTAssertGreaterThan(narrow.height, wide.height, "Evidence strip should stack at compact width")
    }

    func testFixtureSummaryMatchesProvenanceRules() {
        let summary = ResultDesignFixture.summary
        XCTAssertEqual(summary.unreviewedCount, 2)
        XCTAssertEqual(summary.checks, .notReported)
        XCTAssertEqual(summary.progress, .agentReported(completed: 3, total: 4))
    }
}
