import Foundation
import Observation

/// Intentionally self-contained: no client, credentials, persistence, URLs or executable actions.
/// Demo state belongs to its presentation and is discarded when that presentation closes.
@MainActor @Observable final class DemoWorkspace {
    enum Sample: String, CaseIterable, Identifiable {
        case change = "Review a change"
        case research = "Compare options"
        var id: String { rawValue }
        var symbol: String { self == .change ? "chevron.left.forwardslash.chevron.right" : "list.bullet.rectangle" }
        var question: String {
            self == .change ? "Make the workspace tools less distracting on a small screen." : "Help me choose a desk for a small home office."
        }
        var response: String {
            switch self {
            case .change:
                return """
                ## More room for the conversation
                The sample change puts workspace tools inside a collapsible section. Your current conversation stays in place.

                **What changed**
                - Tools are still one tap away.
                - The conversation gets more space on a narrow screen.
                - The control keeps a clear, accessible label.
                """
            case .research:
                return """
                ## Start with the space you have
                For this fictional office, a **120 cm desk** leaves room to move while fitting a laptop and monitor.

                | Option | Width | Best for |
                | --- | --- | --- |
                | Compact | 100 cm | Laptop only |
                | Balanced | 120 cm | Laptop + monitor |
                | Spacious | 160 cm | Two monitors |

                **Recommendation:** measure the wall and chair clearance before buying. These are illustrative dimensions, not live product listings.
                """
            }
        }
        var context: String {
            self == .change ? "The sample change puts workspace tools inside a collapsible section." : "A 120 cm desk leaves room to move while fitting a laptop and monitor."
        }
        var explanation: String {
            self == .change ? "The tools remain available, but they no longer compete with the conversation. Collapsing a secondary section is useful when screen space is limited." : "The middle option balances work surface and floor space. In a real conversation, your agent could compare options against the measurements you provide."
        }
        var checks: String {
            self == .change ? "A real review should check narrow layouts, keyboard navigation and accessibility labels. This demo has not edited files or run a test suite." : "Measure the available width, depth and chair clearance. This sample has not searched stores or verified prices."
        }
    }

    enum Question: String, CaseIterable, Identifiable {
        case why = "Why this recommendation?"
        case checks = "What should I check?"
        case next = "What happens next?"
        var id: String { rawValue }
    }
    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
    }

    private(set) var sample: Sample = .change
    private(set) var exchanges: [Exchange] = []
    private(set) var showingSideChat = false
    private(set) var approved = false
    var toolsExpanded = false

    func select(_ sample: Sample) {
        guard self.sample != sample else { return }
        self.sample = sample
        exchanges = []
        showingSideChat = false
        approved = false
        toolsExpanded = false
    }
    func openSideChat() { showingSideChat = true }
    func closeSideChat() { showingSideChat = false }
    func approveSample() { approved = true }
    func ask(_ question: Question) {
        let answer: String
        switch question {
        case .why: answer = sample.explanation
        case .checks: answer = sample.checks
        case .next: answer = "Exit the demo and choose Set Up Cast to connect your own OpenClaw gateway. This sample never sends messages or runs commands. Real side chats are separate conversations saved on your gateway."
        }
        exchanges.append(Exchange(question: question.rawValue, answer: answer))
        // Keep repeated exploration bounded without writing any history to disk.
        if exchanges.count > 12 { exchanges.removeFirst(exchanges.count - 12) }
    }

    static let diff = """
    --- a/WorkspaceView.swift
    +++ b/WorkspaceView.swift
    @@ -1,2 +1,3 @@
    -Text("Workspace tools")
    -WorkspaceTools()
    +DisclosureGroup("Workspace tools") {
    +    WorkspaceTools()
    +}
    """
}
