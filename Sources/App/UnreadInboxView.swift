import SwiftUI

/// The bell's notification panel: an honest per-chat unread breakdown across every workspace,
/// each row jumping straight to its conversation, plus a way to zero everything in one action.
struct UnreadInboxView: View {
    @ObservedObject var manager: WorkspaceManager
    @Binding var isPresented: Bool

    private var items: [UnreadInboxItem] { self.manager.unreadInbox }
    private var showsWorkspaceName: Bool { self.manager.profiles.count > 1 }

    var body: some View {
        UnreadInboxPanel(
            items: self.items,
            showsWorkspaceName: self.showsWorkspaceName,
            open: { item in
                self.manager.openUnreadInboxItem(item)
                self.isPresented = false
            },
            markAllRead: {
                self.isPresented = false
                self.manager.markAllRead()
            })
    }
}

/// Presentation-independent content shared by the macOS popover and iOS sheet.
struct UnreadInboxPanel: View {
    let items: [UnreadInboxItem]
    let showsWorkspaceName: Bool
    let open: (UnreadInboxItem) -> Void
    let markAllRead: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Unread")
                    .font(.headline)
                Spacer()
                Button("Mark All Read", action: self.markAllRead)
                    .disabled(self.items.isEmpty)
            }
            .padding()
            Divider()
            if self.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No unread conversations")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(self.items) { item in
                            Button {
                                self.open(item)
                            } label: {
                                UnreadInboxRow(
                                    item: item,
                                    showsWorkspaceName: self.showsWorkspaceName)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 240, idealHeight: 420)
    }
}

private struct UnreadInboxRow: View {
    let item: UnreadInboxItem
    let showsWorkspaceName: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(self.item.summary.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if self.showsWorkspaceName {
                        Text(self.item.workspaceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let preview = self.item.summary.preview {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(self.item.summary.accuracy == .lowerBound
                ? "\(self.item.summary.unreadCount)+"
                : "\(self.item.summary.unreadCount)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.blue)
                .accessibilityLabel(self.item.summary.accuracy == .lowerBound
                    ? "At least \(self.item.summary.unreadCount) unread"
                    : "\(self.item.summary.unreadCount) unread")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
