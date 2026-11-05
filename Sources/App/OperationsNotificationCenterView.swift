import SwiftUI

struct OperationsNotificationCenterView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var authorizationMessage: String?

    private var records: [NotificationDeliveryRecord] {
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return self.store.notificationRecords }
        return self.store.notificationRecords.filter { record in
            record.dedupeID.localizedCaseInsensitiveContains(query)
                || record.linkage.sessionKey.localizedCaseInsensitiveContains(query)
                || record.state.label.localizedCaseInsensitiveContains(query)
                || self.title(for: record).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let authorizationMessage {
                    Section {
                        Label(authorizationMessage, systemImage: "bell")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if self.records.isEmpty {
                    ContentUnavailableView(
                        self.query.isEmpty ? "No notifications yet" : "No matching notifications",
                        systemImage: "bell.slash",
                        description: Text("Agent replies and delivery outcomes appear here."))
                } else {
                    ForEach(self.records) { record in
                        Button {
                            self.store.selectedSessionKey = record.linkage.sessionKey
                            self.dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: record.state.symbol)
                                    .foregroundStyle(record.state == .failed ? .red : .blue)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(self.title(for: record))
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(record.state.label)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(record.linkage.sessionKey)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                    if let timestamp = record.transitions.last?.timestamp {
                                        Text(timestamp, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: self.$query, prompt: "Search notification history")
            .navigationTitle("Notification Center")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { self.dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Button("Enable Notifications") {
                        Task {
                            let granted = await self.store.requestNotificationAuthorization()
                            self.authorizationMessage = granted
                                ? "Native alerts and app-icon badges are enabled."
                                : "Notification permission was not granted. In-app history remains available."
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 480)
        #endif
    }

    private func title(for record: NotificationDeliveryRecord) -> String {
        guard let row = self.store.sessions.first(where: {
            SessionKeyMatcher.matches($0.key, record.linkage.sessionKey)
        }) else { return "Agent reply" }
        return SidebarGrouper.displayTitle(for: row, mainSessionKey: self.store.mainSessionKey)
    }
}

private extension NotificationDeliveryState {
    var label: String {
        switch self {
        case .observed: return "Observed"
        case .eligible: return "Eligible"
        case .delivered: return "Delivered"
        case .suppressed: return "In app"
        case .failed: return "Delivery failed"
        case .read: return "Read"
        }
    }

    var symbol: String {
        switch self {
        case .observed: return "eye"
        case .eligible: return "bell"
        case .delivered: return "bell.badge.fill"
        case .suppressed: return "bell.slash"
        case .failed: return "exclamationmark.triangle.fill"
        case .read: return "checkmark.circle"
        }
    }
}
