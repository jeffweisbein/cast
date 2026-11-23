import Foundation
import Observation

/// Attachment imports that have been chosen but are not yet part of a draft.
///
/// Each import is bound to the draft target captured when it was started, so a result lands
/// in the conversation it was picked for even if the operator has moved on. Nothing is
/// shown as attached until preparation has actually succeeded: a tile is either still
/// preparing (and can be cancelled) or has failed (and says why).
@MainActor
@Observable
final class ComposerImportQueue {
    typealias Target = ChatStore.AttachmentDraftTarget

    struct Item: Identifiable, Equatable {
        enum Phase: Equatable {
            case preparing
            case failed(String)
        }

        let id: UUID
        var title: String
        let symbol: String
        let target: Target
        var phase: Phase

        var isPreparing: Bool { self.phase == .preparing }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    /// One queue per store, outliving any single composer view: leaving a conversation must
    /// neither cancel a file that is still being prepared nor lose the reason it failed.
    private static let queues = NSMapTable<ChatStore, ComposerImportQueue>.weakToStrongObjects()

    static func queue(for store: ChatStore) -> ComposerImportQueue {
        if let existing = self.queues.object(forKey: store) { return existing }
        let queue = ComposerImportQueue()
        self.queues.setObject(queue, forKey: store)
        return queue
    }

    func items(for target: Target) -> [Item] {
        self.items.filter { $0.target == target }
    }

    func isPreparing(_ id: UUID) -> Bool {
        self.items.contains { $0.id == id && $0.isPreparing }
    }

    @discardableResult
    func begin(title: String, symbol: String, target: Target) -> UUID {
        let id = UUID()
        self.items.append(Item(id: id, title: title, symbol: symbol, target: target, phase: .preparing))
        return id
    }

    /// Associates the work with its tile so cancelling the tile cancels the work.
    func attach(_ task: Task<Void, Never>, to id: UUID) {
        guard self.isPreparing(id) else { task.cancel(); return }
        self.tasks[id] = task
    }

    func retitle(_ id: UUID, _ title: String) {
        guard let index = self.items.firstIndex(where: { $0.id == id && $0.isPreparing }) else { return }
        self.items[index].title = title
    }

    func finish(_ id: UUID) {
        self.tasks[id] = nil
        self.items.removeAll { $0.id == id }
    }

    func fail(_ id: UUID, message: String) {
        self.tasks[id] = nil
        guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
        self.items[index].phase = .failed(message)
    }

    /// A failure with no work behind it, such as an empty clipboard.
    func report(_ message: String, title: String, symbol: String, target: Target) {
        self.items.append(Item(id: UUID(), title: title, symbol: symbol, target: target, phase: .failed(message)))
    }

    /// Cancels a preparing import or dismisses a failed one.
    func cancel(_ id: UUID) {
        self.tasks[id]?.cancel()
        self.finish(id)
    }

    func clearFailures(for target: Target) {
        self.items.removeAll { $0.target == target && !$0.isPreparing }
    }

    /// True while any import for this draft is still being prepared; sending waits for it so
    /// an attachment can never land in the draft after its message has gone.
    func hasPreparing(for target: Target) -> Bool {
        self.items.contains { $0.target == target && $0.isPreparing }
    }

    func preparingCount(for target: Target) -> Int {
        self.items.filter { $0.target == target && $0.isPreparing }.count
    }

    /// Settles a tile from the destination draft's own answer: accepted removes it, anything
    /// else keeps it visible with the reason, including after the operator switched chats.
    func settle(_ id: UUID, outcome: ChatStore.AttachmentDeliveryOutcome) {
        if let message = outcome.failureMessage {
            self.fail(id, message: message)
        } else {
            self.finish(id)
        }
    }

    /// Runs `work` off the main actor and hands a successful result to `deliver`, which
    /// reports whether the destination draft accepted it. A result that arrives after the
    /// tile was cancelled goes to `discard` and is never attached.
    @discardableResult
    func enqueue(
        title: String,
        symbol: String,
        target: Target,
        work: @escaping @Sendable () async throws -> PreparedAttachment,
        deliver: @escaping @MainActor (PreparedAttachment) -> ChatStore.AttachmentDeliveryOutcome,
        discard: @escaping @MainActor (PreparedAttachment) -> Void = { $0.removeOwnedFile() }) -> UUID
    {
        let id = self.begin(title: title, symbol: symbol, target: target)
        let worker = Task.detached(priority: .userInitiated) { try await work() }
        let task = Task { @MainActor in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard self.isPreparing(id), !Task.isCancelled else {
                if case let .success(attachment) = result { discard(attachment) }
                return
            }
            switch result {
            case let .success(attachment):
                self.settle(id, outcome: deliver(attachment))
            case let .failure(error):
                self.fail(id, message: error.localizedDescription)
            }
        }
        self.attach(task, to: id)
        return id
    }

    /// Delivery that cannot be refused (kept for callers and tests that own the destination).
    @discardableResult
    func enqueue(
        title: String,
        symbol: String,
        target: Target,
        work: @escaping @Sendable () async throws -> PreparedAttachment,
        deliver: @escaping @MainActor (PreparedAttachment) -> Void,
        discard: @escaping @MainActor (PreparedAttachment) -> Void = { $0.removeOwnedFile() }) -> UUID
    {
        self.enqueue(title: title, symbol: symbol, target: target, work: work,
                     deliver: { (attachment: PreparedAttachment) -> ChatStore.AttachmentDeliveryOutcome in
                         deliver(attachment); return .accepted
                     },
                     discard: discard)
    }
}

/// Shared composer limits: the minimum touch target and the one stated reason Send waits.
enum ComposerSendGate {
    static let minimumHitTarget: CGFloat = 44
    static let waitingMessage = "Send waits until attachments finish preparing."

    static func waitingLabel(count: Int) -> String {
        count == 1 ? "Preparing 1 attachment — Send waits until it’s ready."
            : "Preparing \(count) attachments — Send waits until they’re ready."
    }
}
