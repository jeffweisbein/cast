import SwiftUI

struct TasksView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [GatewayTask] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.secondary) }
                if loading { ProgressView("Loading tasks…") }
                if tasks.isEmpty && !loading {
                    ContentUnavailableView("No task records", systemImage: "checklist", description: Text("Task records depend on the connected gateway. Conversations remain available in the sidebar."))
                }
                ForEach(tasks) { task in
                    NavigationLink {
                        TaskDetailView(store: store, taskID: task.id, sessionKey: task.conversationKey)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.displayTitle).font(.headline)
                            Text(task.progressSummary ?? task.terminalSummary ?? task.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                if nextCursor != nil { Button("Load more") { Task { await load(more: true) } }.disabled(loading) }
            }
            .navigationTitle("Tasks")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await load() }.refreshable { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 650, minHeight: 500)
        #endif
    }
    private func load(more: Bool = false) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let page = try await store.taskPage(cursor: more ? nextCursor : nil)
            var seen = Set<String>()
            tasks = ((more ? tasks : []) + page.tasks).filter { seen.insert($0.id).inserted }
            nextCursor = page.nextCursor; error = nil
        } catch { self.error = "Task records could not be loaded. Check the connection and pull to refresh." }
    }
}

struct TaskDetailView: View {
    let store: ChatStore
    let taskID: String?
    let sessionKey: String?
    @Environment(\.dismiss) private var dismiss
    @State private var task: GatewayTask?
    @State private var related: [GatewayTask] = []
    @State private var error: String?
    @State private var loading = false
    @State private var confirmCancel = false
    @State private var confirmRetry = false
    @State private var showingDeliverables = false
    private var key: String? { task?.conversationKey ?? sessionKey }
    private var session: SessionRow? { store.sessions.first { SessionKeyMatcher.matches($0.key, key) } }
    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Updating…") }
                if let error { Text(error).foregroundStyle(.orange) }
                Section("Goal") { Text(task?.prompt ?? task?.displayTitle ?? session?.title ?? "Task details").textSelection(.enabled) }
                Section("Status") {
                    Text(task?.terminalOutcome == "blocked" ? "Blocked" : task?.status ?? (session?.hasActiveRun == true ? "Working" : "See conversation for outcome"))
                    if let note = task?.lastActivity ?? task?.progressSummary ?? session?.modelInfo?.agentStatus?.note { Text(note).textSelection(.enabled) }
                    if let error = task?.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    if let key, let card = store.progressCard(for: key) {
                        if let markdown = card.markdown { Text(markdown).textSelection(.enabled) }
                        ForEach(Array((card.steps ?? []).enumerated()), id: \.offset) { _, step in
                            Label(step.step, systemImage: step.status == .completed ? "checkmark.circle" : "circle")
                        }
                    }
                }
                if let result = task?.result ?? task?.terminalSummary { Section("Result") { Text(result).textSelection(.enabled) } }
                if !related.isEmpty {
                    Section("Related task records") {
                        ForEach(related) { record in
                            NavigationLink(record.displayTitle) {
                                TaskDetailView(store: store, taskID: record.id, sessionKey: record.conversationKey)
                            }
                        }
                    }
                }
                Section("Actions") {
                    if let key {
                        Button("Open conversation / answer") { store.selectedSessionKey = key; dismiss() }
                        Button("View deliverables") { showingDeliverables = true }
                    }
                    if let task, task.isActive, store.gatewayMethods.contains("tasks.cancel") {
                        Button("Stop task", role: .destructive) { confirmCancel = true }.disabled(loading)
                    }
                    if let task, task.canRetryDelivery, store.gatewayMethods.contains("tasks.retry") {
                        Button("Retry result delivery") { confirmRetry = true }.disabled(loading)
                        Text("Retries delivery of the existing result. Does not rerun the task.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if taskID == nil { Text("Session view. Task-specific actions require a gateway task record; no task identity is inferred from this chat’s title.").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle(task?.displayTitle ?? "Work details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading) }
            }
            .task {
                await refresh()
                while task?.isActive == true {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    await refresh()
                }
            }
            .sheet(isPresented: $showingDeliverables) { DeliverablesView(store: store, sessionKey: key) }
            .confirmationDialog("Stop this task?", isPresented: $confirmCancel) {
                Button("Stop task", role: .destructive) { Task { await change(cancel: true) } }
            } message: { Text("Completed changes are not undone by stopping a task.") }
            .confirmationDialog("Retry result delivery?", isPresented: $confirmRetry) {
                Button("Retry delivery") { Task { await change(cancel: false) } }
            } message: { Text("If the earlier delivery succeeded without a receipt, the result may be delivered twice.") }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 480)
        #endif
    }
    private func refresh() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            if let taskID { task = try await store.taskDetail(taskID) }
            else if store.gatewayMethods.contains("tasks.list"), let key {
                let page = try await store.taskPage()
                related = page.tasks.filter { SessionKeyMatcher.matches($0.sessionKey, key) || SessionKeyMatcher.matches($0.childSessionKey, key) }
            }
            if let key { await store.loadProgressForDetails(key) }
            error = nil
        } catch { self.error = "Couldn’t refresh task details. Displayed information may be out of date." }
    }
    private func change(cancel: Bool) async {
        guard let task, !loading else { return }; loading = true
        do { try await store.changeTask(task, cancel: cancel); error = nil }
        catch { self.error = error.localizedDescription; loading = false; return }
        loading = false; await refresh(); await store.refreshSessions()
    }
}
