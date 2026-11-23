import SwiftUI

struct ConnectionStatusView: View {
    let store: ChatStore
    var showsWhenHealthy = true
    var compact = false
    @State private var expanded = false
    @State private var showingDetails = false
    private var unconfirmed: Int {
        store.messages.filter { $0.localDeliveryState == .pending || $0.localDeliveryState == .uncertain || $0.localDeliveryState == .failed }.count
    }
    private var connected: Bool { if case .connected = store.connectionState { return true }; return false }
    var body: some View {
        if showsWhenHealthy || !connected || unconfirmed > 0 {
            statusContent
        }
    }

    private var statusContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if compact { showingDetails = true } else { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: connected ? "checkmark.circle" : "wifi.exclamationmark")
                        .foregroundStyle(connected ? Color.green : Color.orange)
                    Text(ConnectionPresentation.title(store.connectionState))
                    if unconfirmed > 0 { Text("· \(unconfirmed) unconfirmed") }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
                .frame(minHeight: compact ? 44 : nil)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Connection status: " + ConnectionPresentation.title(store.connectionState) + (unconfirmed > 0 ? ", \(unconfirmed) unconfirmed messages" : ""))
            if !compact && (expanded || !connected || unconfirmed > 0) {
                Text(ConnectionPresentation.detail(store.connectionState, unconfirmed: unconfirmed))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .disconnected = store.connectionState {
                    Button("Reconnect") { store.restartWithStoredCredential() }.font(.caption)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, compact ? 0 : 8).background(.regularMaterial)
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                VStack { ConnectionStatusView(store: store); Spacer() }
                    .navigationTitle("Connection")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
