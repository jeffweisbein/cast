import SwiftUI

/// Transient chooser for pinned chats, in the user's pinned order, ending with New chat.
/// Grows up from the bottom controls (or down from the chat's leading toolbar item).
struct PinnedChatSwitcher: View {
    let store: ChatStore
    let onSelect: (String) -> Void
    let onNewChat: () -> Void

    private var entries: [PinnedSwitcherEntry] {
        let chats = self.store.personalChats
        let pinned = chats.filter { self.store.isSessionPinned($0.key) }
        return PinnedSwitcher.entries(
            chats: pinned,
            isPinned: { self.store.isSessionPinned($0) },
            title: { self.store.chatTitle($0) },
            selectedKey: self.store.selectedSessionKey,
            unread: { self.store.unreadCount(for: $0.key) > 0 || $0.isUnread },
            states: self.store.chatWorkStates(for: pinned))
    }

    var body: some View {
        let entries = self.entries
        VStack(alignment: .leading, spacing: 0) {
            Text("Pinned")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            if entries.isEmpty {
                Text("Pin a chat from its ••• menu to switch here quickly.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            Button { self.onSelect(entry.key) } label: { self.row(entry) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("pinned-switch-" + entry.key)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 360)
            }
            Divider().padding(.top, 4)
            Button(action: self.onNewChat) {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pinned-switch-new-chat")
            .padding(.bottom, 4)
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
    }

    private func row(_ entry: PinnedSwitcherEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isSelected ? "checkmark" : "pin.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(entry.isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(entry.unread ? .body.weight(.semibold) : .body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let state = entry.state {
                    ChatWorkStateLabel(state: state)
                }
            }
            Spacer(minLength: 8)
            if entry.unread {
                Circle().fill(.blue).frame(width: 7, height: 7).accessibilityLabel("Unread")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(entry.isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(entry.isSelected ? .isSelected : [])
    }
}

#if os(iOS)
/// Opens the switcher and applies the choice only after the popover has gone, so the
/// dismissal and the chat push never fight over the same transition.
private struct PinnedSwitcherPresenter: ViewModifier {
    let store: ChatStore
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    @State private var pendingKey: String?
    @State private var pendingNewChat = false

    func body(content: Content) -> some View {
        content
            .popover(isPresented: self.$isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: self.arrowEdge) {
                PinnedChatSwitcher(store: self.store, onSelect: { key in
                    self.pendingKey = key
                    self.isPresented = false
                }, onNewChat: {
                    self.pendingNewChat = true
                    self.isPresented = false
                })
                .presentationCompactAdaptation(.popover)
            }
            .onChange(of: self.isPresented) { _, presented in
                guard !presented else { return }
                if let key = self.pendingKey {
                    self.pendingKey = nil
                    self.store.selectFromSidebar(key)
                }
                if self.pendingNewChat {
                    self.pendingNewChat = false
                    self.store.newPersonalChatPresented = true
                }
            }
    }
}

/// Thumb-zone controls under the chat list: the pinned switcher and a separate New chat.
struct ChatsBottomControls: View {
    let store: ChatStore
    @State private var showingSwitcher = false

    var body: some View {
        let hasPinned = self.store.personalChats.contains { self.store.isSessionPinned($0.key) }
        HStack(spacing: 12) {
            if hasPinned {
                Button { self.showingSwitcher = true } label: {
                    Label("Pinned", systemImage: "pin")
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 4)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Switch pinned chat")
                .accessibilityIdentifier("pinned-switcher")
                .modifier(PinnedSwitcherPresenter(store: self.store, isPresented: self.$showingSwitcher, arrowEdge: .bottom))
            }
            Spacer(minLength: 0)
            Button { self.store.newPersonalChatPresented = true } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 4)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("New chat")
            .accessibilityIdentifier("personal-new-chat")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

/// Compact chat detail: one tap from any chat to another pinned chat.
struct PinnedSwitcherToolbarButton: View {
    let store: ChatStore
    @State private var showingSwitcher = false

    var body: some View {
        Button { self.showingSwitcher = true } label: {
            Label("Pinned chats", systemImage: "pin")
        }
        .accessibilityIdentifier("pinned-switcher-detail")
        .modifier(PinnedSwitcherPresenter(store: self.store, isPresented: self.$showingSwitcher, arrowEdge: .top))
    }
}
#endif
