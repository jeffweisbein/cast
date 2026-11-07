import SwiftUI

struct QuestionCardView: View {
    let store: ChatStore
    let requestID: String
    var showsConversation = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let entry = store.questionInbox.entries[requestID] {
                let pending = entry.request.isPending(at: context.date)
                VStack(alignment: .leading, spacing: 16) {
                    let state = ActionPresentation.question(entry, at: context.date)
                    Label(state.rawValue, systemImage: state == .confirmed ? "checkmark.bubble" : "questionmark.bubble")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    if showsConversation {
                        Text(conversationTitle(entry.request)).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(entry.request.questions, id: \.questionId) { question in
                        VStack(alignment: .leading, spacing: 10) {
                            if let header = question.header, !header.isEmpty {
                                Text(header).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(question.question).font(.body).textSelection(.enabled)
                            if let raw = question.url, let url = URL(string: raw),
                               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                                Link("View reference", destination: url)
                            }
                            if pending {
                                if question.multiSelect == true { Text("Choose all that apply").font(.caption).foregroundStyle(.secondary) }
                                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                                    optionButton(option, question: question, entry: entry)
                                }
                                if question.allowsText {
                                    if !question.options.isEmpty {
                                        Button {
                                            changeDraft(entry) { draft in
                                                if draft.usingOther.contains(question.questionId) { draft.usingOther.remove(question.questionId) }
                                                else {
                                                    draft.usingOther.insert(question.questionId)
                                                    if question.multiSelect != true { draft.selections[question.questionId] = [] }
                                                }
                                            }
                                        } label: {
                                            Label("Other answer", systemImage: entry.draft.usingOther.contains(question.questionId) ? "checkmark.circle.fill" : "circle")
                                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                                        }.buttonStyle(.bordered)
                                        .accessibilityValue(entry.draft.usingOther.contains(question.questionId) ? "Selected" : "Not selected")
                                    }
                                    if question.options.isEmpty || entry.draft.usingOther.contains(question.questionId) {
                                        TextField("Your answer", text: Binding(
                                            get: { store.questionInbox.entries[requestID]?.draft.text[question.questionId] ?? "" },
                                            set: { value in changeDraft(entry) { $0.text[question.questionId] = value } }), axis: .vertical)
                                            .textFieldStyle(.roundedBorder).lineLimit(2...6)
                                            .accessibilityLabel("Answer: " + question.question)
                                    }
                                }
                            }
                        }
                        .disabled(entry.submitting || entry.uncertain)
                    }
                    if let error = entry.error, pending {
                        Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("question-error")
                    }
                    if pending {
                        if !isConnected { Text("Offline — your draft is kept until you reconnect.").font(.caption).foregroundStyle(.secondary) }
                        if !store.questionsEnabled && !store.secretEntryEnabled {
                            Button("Enable question cards") { store.setQuestionsEnabled(true) }
                        }
                        HStack {
                            Button(entry.submitting ? "Submitting…" : entry.uncertain ? "Retry same answer" : "Submit answer") {
                                Task { await store.submitQuestion(id: requestID, sessionKey: entry.request.sessionKey) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(entry.submitting || !isConnected || (!store.questionsEnabled && !store.secretEntryEnabled) || entry.draft.answers(for: entry.request) == nil)
                            .accessibilityIdentifier("question-submit")
                            if entry.submitting { ProgressView().controlSize(.small) }
                            if entry.error != nil {
                                Button("Refresh status") { Task { await store.refreshQuestion(id: requestID) } }.disabled(!isConnected || entry.submitting)
                            }
                        }
                        Text("Expires " + Date(timeIntervalSince1970: entry.request.expiresAtMs / 1000).formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(entry.request.status == "answered" ? "The Gateway recorded an answer. No further response is needed." : "This question is no longer accepting answers.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Dismiss") { store.questionInbox.dismiss(id: requestID) }.buttonStyle(.bordered)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.25)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("question-card-" + requestID)
            }
        }
    }

    private var isConnected: Bool { if case .connected = store.connectionState { return true }; return false }
    private func conversationTitle(_ request: QuestionRequest) -> String {
        if let session = store.sessions.first(where: { request.belongs(to: $0.key) }) { return session.title }
        return request.sessionKey ?? request.agentId.map { "Agent: " + $0 } ?? "Workspace question"
    }
    private func changeDraft(_ entry: QuestionInbox.Entry, update: (inout QuestionDraft) -> Void) {
        var draft = store.questionInbox.entries[entry.id]?.draft ?? entry.draft
        update(&draft)
        store.questionInbox.updateDraft(id: entry.id, draft: draft)
    }
    private func optionButton(_ option: QuestionRequest.Question.Option, question: QuestionRequest.Question, entry: QuestionInbox.Entry) -> some View {
        let selected = entry.draft.selections[question.questionId, default: []].contains(option.label)
        return Button {
            changeDraft(entry) { draft in
                if question.multiSelect == true {
                    if selected { draft.selections[question.questionId, default: []].remove(option.label) }
                    else { draft.selections[question.questionId, default: []].insert(option.label) }
                } else {
                    draft.selections[question.questionId] = [option.label]
                    draft.usingOther.remove(question.questionId)
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.label).fontWeight(selected ? .semibold : .regular)
                    if let description = option.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.bordered)
        .accessibilityLabel(option.label + (option.description.map { ". " + $0 } ?? ""))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(question.multiSelect == true ? "Toggle this choice" : "Select this choice")
    }
}

struct QuestionInboxView: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Enable question cards", isOn: Binding(get: { store.questionsEnabled }, set: { store.setQuestionsEnabled($0) }))
                    Text("Answer your agent here without typing a chat reply. Enabling may require device permission approval in OpenClaw. Secure credentials and execution approvals remain separate.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = store.questionError { Text(error).foregroundStyle(.red) }
                    if store.questionInbox.sorted.isEmpty { Text("No questions waiting in this workspace.").foregroundStyle(.secondary) }
                    ForEach(store.questionInbox.sorted) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            QuestionCardView(store: store, requestID: entry.id, showsConversation: true)
                            if let key = entry.request.sessionKey {
                                Button("Open conversation") { store.selectedSessionKey = key; dismiss() }
                            }
                        }
                    }
                    Button("Refresh questions") { Task { await store.refreshQuestions() } }
                }.padding().frame(maxWidth: 760)
            }
            .navigationTitle("Questions")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.refreshQuestions() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }
}
