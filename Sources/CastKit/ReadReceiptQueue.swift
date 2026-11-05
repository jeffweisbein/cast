import Foundation

/// One gateway read receipt at a time, coalesced by chat. The local badge transaction never
/// waits for this queue. A later click replaces queued work for that chat, not other chats.
@MainActor
final class ReadReceiptQueue {
    private var pending: [String: () async -> Void] = [:]
    private var order: [String] = []
    private var worker: Task<Void, Never>?

    func enqueue(key: String, operation: @escaping () async -> Void) {
        if self.pending[key] == nil { self.order.append(key) }
        self.pending[key] = operation
        guard self.worker == nil else { return }
        self.worker = Task { [weak self] in
            guard let self else { return }
            var index = 0
            while index < self.order.count {
                let key = self.order[index]
                index += 1
                guard let operation = self.pending.removeValue(forKey: key) else { continue }
                await Task.yield()
                await operation()
            }
            self.order.removeAll(keepingCapacity: true)
            self.worker = nil
        }
    }
}
