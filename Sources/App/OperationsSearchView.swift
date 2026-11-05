import SwiftUI

struct OperationsSearchView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var remote = false
    @State private var includeHidden = false
    @State private var results: [OperationsSearchResult] = []
    @State private var loading = false
    @State private var notice: String?
    @State private var generation = UUID()
    @State private var deliverable: OperationsSearchResult?
    @State private var task: OperationsSearchResult?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Include hidden chats", isOn: $includeHidden)
                    Toggle("Search gateway history too", isOn: $remote)
                        .disabled(!store.gatewayMethods.contains("sessions.search"))
                    Text(remote ? "Gateway results include uncached history from listed conversations, within your gateway access." : "Searching saved messages, session titles, attention items, and deliverables on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                    if loading { ProgressView("Searching…") }
                    if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
                if !loading && results.isEmpty {
                    ContentUnavailableView(query.count < 2 ? "Find past work" : "No matches", systemImage: "magnifyingglass",
                        description: Text(query.count < 2 ? "Enter at least two characters." : "Try another phrase or include gateway history."))
                }
                ForEach(results) { result in
                    Button {
                        if result.kind == .deliverable { deliverable = result }
                        else if result.kind == .task { task = result }
                        else {
                            store.selectedSessionKey = result.sessionKey
                            store.searchFocusSessionKey = result.sessionKey
                            store.searchFocusExcerpt = result.messageID == nil ? nil : result.detail
                            store.searchFocusMessageID = result.messageID
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(result.title).font(.headline).foregroundStyle(.primary)
                            Text(result.detail).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                            Text("\(result.kind.rawValue) · \(result.source)").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Search conversations, tasks, files…")
            .navigationTitle("Search this workspace")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: "\(query)|\(remote)|\(includeHidden)") { await search() }
            .sheet(item: $deliverable) { hit in DeliverablesView(store: store, sessionKey: hit.sessionKey, initialItemID: hit.referenceID) }
            .sheet(item: $task) { hit in TaskDetailView(store: store, taskID: hit.referenceID, sessionKey: hit.sessionKey) }
        }
        #if os(macOS)
        .frame(minWidth: 650, minHeight: 500)
        #endif
    }

    private func search() async {
        let token = UUID(); generation = token
        notice = nil
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { results = []; loading = false; return }
        loading = true
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        let text = query
        var found = await store.localOperationsSearch(text, includeHidden: includeHidden)
        guard !Task.isCancelled, generation == token else { return }
        results = found
        if remote {
            do {
                let response = try await store.remoteOperationsSearch(text)
                guard !Task.isCancelled, generation == token else { return }
                found += response.results.map { hit in
                    OperationsSearchResult(id: "message:\(hit.sessionKey)-\(hit.messageId)", kind: .message,
                        title: store.sessions.first { SessionKeyMatcher.matches($0.key, hit.sessionKey) }?.title ?? "Conversation",
                        detail: hit.snippet, sessionKey: hit.sessionKey, messageID: hit.messageId, referenceID: nil, source: "Gateway history")
                }
                notice = response.indexing == true ? "Gateway indexing is in progress; results may be incomplete."
                    : (response.truncated == true ? "Showing the first gateway matches. Refine your query for more precise results." : nil)
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                notice = "Gateway search is unavailable. Local results are still shown."
            }
            if store.gatewayMethods.contains("tasks.list") {
                do {
                    let page = try await store.taskPage()
                    guard !Task.isCancelled, generation == token else { return }
                    found += page.tasks.compactMap { task in
                        guard let key = task.conversationKey else { return nil }
                        return OperationsSearchResult(id: "task:" + task.id, kind: .task, title: task.displayTitle,
                            detail: task.progressSummary ?? task.terminalSummary ?? task.status, sessionKey: key,
                            messageID: nil, referenceID: task.id, source: "Recent gateway tasks")
                    }
                    if page.nextCursor != nil { notice = (notice.map { $0 + " " } ?? "") + "Task search covers the most recent 100 tasks." }
                } catch {
                    guard !Task.isCancelled, generation == token else { return }
                    notice = (notice.map { $0 + " " } ?? "") + "Gateway task results unavailable."
                }
            }
        }
        guard !Task.isCancelled, generation == token else { return }
        results = OperationsSearch.ranked(found, query: text, hidden: store.sidebarPreferences.hiddenKeys, includeHidden: includeHidden)
        loading = false
    }
}
