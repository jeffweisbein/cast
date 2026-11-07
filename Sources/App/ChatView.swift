import AVFoundation
import CoreTransferable
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

enum TranscriptLayoutStrategy: String, CaseIterable {
    case safeAreaComposerLazy = "safe-area-lazy"
    case detachedComposerLazy = "detached-lazy"
    case detachedComposerEager = "detached-eager"

    #if os(macOS)
    // detached-lazy (LazyVStack) livelocks the macOS main thread on session switch: its
    // placement never converges, pinning a core at 100%. Eager survives the deterministic
    // watchdog and idles at 0% CPU in the real app. See docs/diagnostics/README.md. Revert to
    // lazy once the LazyVStack placement loop itself is fixed.
    static let productionDefault: Self = .detachedComposerEager
    #else
    // The livelock is macOS-specific; retain lazy rendering on iOS, where eager transcript
    // performance has not been validated and the freeze has not reproduced.
    static let productionDefault: Self = .detachedComposerLazy
    #endif

    var usesDetachedComposer: Bool { self != .safeAreaComposerLazy }
    var usesLazyTranscript: Bool { self != .detachedComposerEager }
    /// Independent of lazy vs eager rows. An unwindowed `LazyVStack` still has to estimate
    /// offsets across hundreds of unrealized rows, and those estimates are what left the iOS
    /// transcript parked short of the tail.
    var usesWindowedTranscript: Bool { true }
}

struct ChatView: View {
    let store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    let layoutStrategy: TranscriptLayoutStrategy
    let allowsSending: Bool
    let showsComposer: Bool
    @AppStorage("showAgentWork") private var showAgentWork = true
    // Transient view state (spec: no persistence for tool-run expansion).
    @State private var expandedRuns: Set<String> = []
    @State private var showingLibrary = false
    @State private var showingSecretRequests = false
    @State private var showingQuestions = false
    @State private var previewURL: URL?
    @State private var documentLink: DocumentLink?
    @State private var nearBottom = true
    @State private var atBottom = true
    @State private var followState = TranscriptFollowState()
    @State private var transcriptWindow = TranscriptWindow()
    @State private var readingWindowStartID: String?
    @State private var readingWindowEndID: String?
    @State private var focusedSearchItemID: String?
    @State private var navigation = TranscriptNavigation()
    @State private var topVisibleItemID: String?
    @State private var showingFind = false
    @State private var findQuery = ""
    @State private var findMatches: [String] = []
    @State private var findIndex = -1
    @State private var navigationJumpVersion = 0
    @State private var navigationNotice: String?
    @State private var scrollPosition = ScrollPosition()
    /// Tail the reader was on when they stopped following, so the "Latest" pill can say how
    /// much has landed since. Only reliable now that message identifiers are stable.
    @State private var followAnchorID: String?
    @State private var lastTailID: String?
    /// Bounded so a transcript that genuinely cannot reach its own tail stops trying instead
    /// of re-scrolling on every geometry callback forever.
    @State private var reanchorAttempts = 0
    @State private var needsForegroundReanchor = false
    static let reanchorAttemptLimit = 3
    @FocusState private var composerFocused: Bool

    init(
        store: ChatStore,
        layoutStrategy: TranscriptLayoutStrategy = .productionDefault,
        allowsSending: Bool = true,
        showsComposer: Bool = true)
    {
        self.store = store
        self.layoutStrategy = layoutStrategy
        self.allowsSending = allowsSending
        self.showsComposer = showsComposer
    }

    private var items: [TranscriptItem] {
        self.store.transcriptItems(showAgentWork: self.showAgentWork)
    }

    private var windowSelection: TranscriptWindowSelection {
        self.transcriptWindow.selection(
            totalItemCount: self.items.count,
            anchoredStartIndex: self.readingWindowStartID.flatMap { id in
                self.items.firstIndex { $0.id == id }
            },
            anchoredEndIndex: self.readingWindowEndID.flatMap { id in
                self.items.firstIndex { $0.id == id }.map { $0 + 1 }
            })
    }

    private var visibleItems: ArraySlice<TranscriptItem> {
        if let focusedSearchItemID, let index = items.firstIndex(where: { $0.id == focusedSearchItemID }) {
            return items[TranscriptWindow.searchRange(index: index, total: items.count)]
        }
        guard self.layoutStrategy.usesWindowedTranscript else { return self.items[...] }
        return self.windowSelection.items(from: self.items)
    }

    private func focusSearchMatch() {
        guard SessionKeyMatcher.matches(store.searchFocusSessionKey, store.selectedSessionKey),
              let messageID = store.searchFocusMessageID,
              let index = items.firstIndex(where: { item in
                  if case .group(let group) = item { return group.messages.contains { $0.id == messageID } }
                  return false
              }) else { return }
        let itemID = items[index].id
        rememberReadingPlace()
        // A deep search must not expand an eager Mac transcript to tens of thousands
        // of rows. Show a bounded neighborhood until the reader chooses Latest.
        if index < windowSelection.range.lowerBound { focusedSearchItemID = itemID }
        nearBottom = false
        followState.scrollPhaseChanged(userDriven: true, isNearBottom: false)
        store.searchFocusMessageID = nil
        store.searchFocusExcerpt = nil
        jump(to: itemID)

    }

    /// Explicit jump to the tail.
    ///
    /// This used to be a hand-rolled six-pass settle loop, because late layout (async media,
    /// highlighted code, streamed deltas) kept landing after a single `scrollTo`. The system
    /// does that now: `.defaultScrollAnchor(_:for: .sizeChanges)` re-anchors on every content
    /// size change with no timer. What is left here is deliberate movement only — opening a
    /// session, the "Latest" pill, and the frame changes the anchor role does not observe.
    private func scrollToBottom(animated: Bool = true) {
        navigationJumpVersion += 1
        focusedSearchItemID = nil
        // Reveal the real tail before requesting movement. If already at the frozen
        // window's bottom, no geometry callback would arrive to unpin it later.
        if self.readingWindowStartID != nil || self.readingWindowEndID != nil {
            self.readingWindowStartID = nil
            self.readingWindowEndID = nil
            self.transcriptWindow.reset()
        }
        guard self.scenePhase == .active else {
            self.needsForegroundReanchor = true
            CastLifecycleDiagnostics.scrollRequested(deferred: true)
            return
        }
        self.needsForegroundReanchor = false
        CastLifecycleDiagnostics.scrollRequested(deferred: false)
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { self.scrollPosition.scrollTo(edge: .bottom) }
        } else {
            self.scrollPosition.scrollTo(edge: .bottom)
        }
    }

    /// Remembers the tail the reader left behind when following stops, and forgets it the
    /// moment they are following again.
    private func syncFollowAnchor() {
        if self.followState.followsLatest {
            // Guarded: this runs on every scroll-geometry sample, and an unconditional write
            // to a non-trivial `@State` invalidates the whole transcript body per sample.
            if self.followAnchorID != nil { self.followAnchorID = nil }
            if self.readingWindowStartID != nil {
                self.readingWindowStartID = nil
                self.readingWindowEndID = nil
                self.transcriptWindow.reset()
            }
        } else if self.followAnchorID == nil {
            self.readingWindowEndID = self.visibleItems.last?.id
            self.readingWindowStartID = self.visibleItems.first?.id
            self.followAnchorID = self.store.messages.last?.id
        }
    }

    private var missedMessageCount: Int {
        guard let anchor = self.followAnchorID,
              let index = self.store.messages.lastIndex(where: { $0.id == anchor })
        else { return 0 }
        return self.store.messages.count - (index + 1)
    }

    private var title: String {
        guard let key = self.store.selectedSessionKey else { return "" }
        guard let session = self.store.sessions.first(where: { $0.key == key }) else { return key }
        return SidebarGrouper.displayTitle(for: session, mainSessionKey: self.store.mainSessionKey)
    }

    @ViewBuilder
    private var transcriptRows: some View {
        if focusedSearchItemID == nil, self.layoutStrategy.usesWindowedTranscript,
           self.windowSelection.canShowEarlier
        {
            Button {
                let anchor = self.visibleItems.first?.id
                self.followState.scrollPhaseChanged(userDriven: true, isNearBottom: false)
                self.transcriptWindow.showEarlier(
                    totalItemCount: self.items.count,
                    anchoredStartIndex: self.windowSelection.range.lowerBound)
                self.readingWindowStartID = self.visibleItems.first?.id
                Task { @MainActor in
                    await Task.yield()
                    if let anchor { self.scrollPosition.scrollTo(id: anchor, anchor: .top) }
                }
            } label: {
                Label(
                    "Show Earlier",
                    systemImage: "arrow.up.to.line")
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(
                "Show \(self.windowSelection.nextExpansionItemCount) earlier transcript items")
        }
        ForEach(self.visibleItems) { item in
            self.itemView(item).id(item.id)
                .overlay(alignment: .leading) {
                    if showingFind, currentFindMatchID == item.id {
                        RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 2).allowsHitTesting(false)
                    }
                }
        }
        if self.showAgentWork {
            ForEach(self.store.approvals) { approval in
                ApprovalCardView(approval: approval, store: self.store)
            }
        }
        ForEach(store.questionInbox.sorted.filter { $0.request.belongs(to: store.selectedSessionKey) }) { entry in
            QuestionCardView(store: store, requestID: entry.id)
        }
        LiveTranscriptTail(store: self.store, showAgentWork: self.showAgentWork, allowsSending: self.allowsSending)
            .id("streaming")
    }

    @ViewBuilder
    private var transcriptStack: some View {
        if self.layoutStrategy.usesLazyTranscript {
            LazyVStack(alignment: .leading, spacing: 20) {
                self.transcriptRows
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                self.transcriptRows
            }
        }
    }

    private var transcriptScrollBody: some View {
        ScrollView {
            self.transcriptStack
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(self.$scrollPosition)
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.1) { ids in
            let visible = Set(ids)
            let first = visibleItems.first(where: { visible.contains($0.id) })?.id
            if topVisibleItemID != first { topVisibleItemID = first }
        }
        .defaultScrollAnchor(.bottom)
        // The systemic fix for late layout: async images, highlighted code blocks and
        // streamed deltas all re-anchor here with no timer of ours. Suppressed while the
        // reader is not following the tail, so prepending an older history page — or the
        // "Show Earlier" window expansion — cannot yank them back down.
        .defaultScrollAnchor(self.followState.followsLatest ? .bottom : nil, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.canvas)
        #if os(macOS)
        .background(TranscriptWheelObserver { scrollingUp in
            var state = self.followState
            if TranscriptNavigation.shouldResumeForWheel(scrollingUp: scrollingUp, atBottom: atBottom, focused: focusedSearchItemID != nil) {
                state.resume()
            } else {
                state.scrollPhaseChanged(userDriven: true, isNearBottom: false)
            }
            if state != self.followState { self.followState = state }
            self.syncFollowAnchor()
        })
        #endif
        .overlay {
            if self.items.isEmpty,
               !self.store.isAgentTurnActive,
               self.store.approvals.isEmpty,
               !self.store.questionInbox.sorted.contains(where: { $0.request.belongs(to: store.selectedSessionKey) })
            {
                self.emptyTranscriptView
                    .padding(28)
                    .allowsHitTesting(false)
            }
        }
        .onScrollGeometryChange(for: TranscriptScrollReading.self) { geometry in
            TranscriptScrollReading(
                containerHeight: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height,
                offset: geometry.contentOffset.y)
        } action: { previous, reading in
            guard focusedSearchItemID == nil else {
                if nearBottom { nearBottom = false }
                return
            }
            guard let isNear = reading.isNearBottom else { return }
            // Geometry also moves when rows/media settle. On macOS real wheel intent is
            // observed above; treating those layout shifts as input incorrectly pauses a
            // completely untouched transcript.
            #if os(macOS)
            let readerScrolledAway = false
            #else
            let readerScrolledAway = reading.indicatesReaderScroll(from: previous)
            #endif
            if self.nearBottom != isNear { self.nearBottom = isNear }
            if self.atBottom != reading.isAtBottom { self.atBottom = reading.isAtBottom }
            // Geometry samples arrive on every scrolled pixel and every content growth. Writing
            // `@State` for each one re-evaluated this whole view, rows included, mid-scroll.
            var followState = self.followState
            followState.geometryChanged(
                isNearBottom: reading.isAtBottom && reading.offset >= previous.offset,
                readerScrolledAway: readerScrolledAway)
            if followState != self.followState { self.followState = followState }
            self.syncFollowAnchor()
            if isNear {
                if self.reanchorAttempts != 0 { self.reanchorAttempts = 0 }
            } else if TranscriptReanchorPolicy.shouldNudge(
                previous: previous,
                current: reading,
                followsLatest: self.followState.followsLatest,
                attempts: self.reanchorAttempts,
                limit: Self.reanchorAttemptLimit)
            {
                // The `.sizeChanges` anchor above catches content that *grows*. A lazy
                // transcript also merely settles — rows realize and swap their estimated
                // heights for real ones without a growth event big enough to land the tail.
                // A reader who never scrolled away should never be left looking at blank
                // canvas, so nudge back, bounded, and never against the reader's own scroll.
                self.reanchorAttempts += 1
                self.scrollToBottom(animated: false)
            }
        }
    }

    // Persisted rows can be replaced without growing content height, and streaming lives
    // outside transcriptRevision. Observe both, not just ScrollView size changes.
    private struct TailUpdate: Equatable {
        let sessionKey: String?
        let revision: Int
        let text: String
        let reasoning: String
        let active: Bool
    }

    private var tailUpdate: TailUpdate {
        TailUpdate(sessionKey: store.selectedSessionKey, revision: store.transcriptRevision,
                   text: store.streamingText, reasoning: store.streamingReasoningText,
                   active: store.isAgentTurnActive)
    }

    private var liveTranscriptBody: some View {
        self.transcriptScrollBody
        .task(id: self.tailUpdate) {
            let sessionKey = self.store.selectedSessionKey
            guard self.followState.followsLatest, self.focusedSearchItemID == nil else { return }
            // Let the new rows enter layout first. Recheck intent afterwards: a wheel
            // gesture or search during this yield must cancel the automatic movement.
            await Task.yield()
            guard !Task.isCancelled,
                  self.store.selectedSessionKey == sessionKey,
                  self.followState.followsLatest,
                  self.focusedSearchItemID == nil else { return }
            self.reanchorAttempts = 0
            self.scrollToBottom(animated: false)
        }
    }

    private var transcriptView: some View {
        self.liveTranscriptBody
        .onChange(of: store.searchFocusMessageID) { _, _ in
            Task { @MainActor in await Task.yield(); focusSearchMatch() }
        }
        .onChange(of: store.transcriptRevision) { _, _ in
            Task { @MainActor in await Task.yield(); focusSearchMatch() }
        }
        .onScrollPhaseChange { _, phase in
            #if !os(macOS)
            let userDriven: Bool
            switch phase {
            case .tracking, .interacting, .decelerating:
                userDriven = true
            case .idle, .animating:
                userDriven = false
            @unknown default:
                userDriven = false
            }
            var state = self.followState
            state.scrollPhaseChanged(userDriven: userDriven, isNearBottom: self.nearBottom)
            if state != self.followState { self.followState = state }
            self.syncFollowAnchor()
            #endif
            // macOS intent is owned by TranscriptWheelObserver. SwiftUI also emits
            // phases during layout/programmatic movement; those must not freeze the
            // reading window and hide new messages behind the Latest button.
        }
        .overlay(alignment: .bottom) {
            if !self.followState.followsLatest || !self.nearBottom {
                let missed = self.missedMessageCount
                Button {
                    self.followState.resume()
                    self.followAnchorID = nil
                    self.reanchorAttempts = 0
                    self.scrollToBottom()
                } label: {
                    Label(missed > 0 ? "Latest · \(missed)" : "Latest", systemImage: "arrow.down")
                        .font(.caption.weight(.semibold))
                        .fontDesign(.rounded)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityLabel(
                    missed > 0
                        ? "Jump to latest message, \(missed) new"
                        : "Jump to latest message")
            }
        }
        .onChange(of: self.store.transcriptRevision) {
            // Not `messages.count`: a history reconcile replaces rows in place, so the count
            // is unchanged and this never fired — the exact reason reopening a session left
            // readers parked at the top. Compare the tail identity instead, which is only
            // meaningful now that message ids survive a reconcile.
            let tailID = self.store.messages.last?.id
            let tailChanged = tailID != self.lastTailID
            self.lastTailID = tailID
            if tailChanged, self.store.messages.last?.isUser == true {
                // I just sent: always follow, wherever I was reading.
                self.followState.resume()
                self.followAnchorID = nil
                self.scrollToBottom()
            }
            // Automatic following is coalesced by the tailUpdate task above, after
            // layout and a fresh intent check, including same-height replacements.
        }
        .onChange(of: self.store.pendingAttachments.count) {
            // A detached composer changes the scroll view's actual frame instead of its
            // safe-area proposal, and a frame change is not a content size change — the
            // `.sizeChanges` anchor above never sees it.
            if self.followState.followsLatest {
                self.scrollToBottom(animated: false)
            }
        }
        .onChange(of: self.composerFocused) { _, focused in
            CastLifecycleDiagnostics.composerFocusChanged(focused: focused)
            // Same shape as the attachment case: the keyboard shrinks the scroll view's real
            // frame, so without this the newest row slides out of view and stays there.
            guard focused, self.followState.followsLatest else { return }
            self.scrollToBottom(animated: false)
        }
        .onChange(of: self.store.selectedSessionKey) {
            self.nearBottom = true
            self.atBottom = true
            self.followState.resume()
            self.followAnchorID = nil
            self.reanchorAttempts = 0
            self.transcriptWindow.reset()
            self.readingWindowStartID = nil
            self.readingWindowEndID = nil
            self.scrollToBottom(animated: false)
        }
        .onChange(of: self.showAgentWork) {
            self.transcriptWindow.reset()
            self.readingWindowStartID = nil
            self.readingWindowEndID = nil
            if self.followState.followsLatest {
                self.scrollToBottom(animated: false)
            }
        }
        .onAppear {
            // Reopening a session Cast already has cached rows for populates `messages`
            // before this view appears, so no transcript change follows to re-anchor.
            self.nearBottom = true
            self.atBottom = true
            self.followState.resume()
            self.followAnchorID = nil
            self.reanchorAttempts = 0
            self.transcriptWindow.reset()
            self.readingWindowStartID = nil
            self.readingWindowEndID = nil
            self.lastTailID = self.store.messages.last?.id
            self.scrollToBottom(animated: false)
        }
        .onChange(of: self.scenePhase) { _, phase in
            guard phase == .active,
                  self.followState.followsLatest,
                  self.needsForegroundReanchor
            else { return }
            // Exactly one deferred mutation after activation; no scroll-position writes
            // occur while UIKit is backgrounded or transitioning through inactive.
            self.scrollToBottom(animated: false)
        }
    }

    @ViewBuilder
    private var transcriptAndComposer: some View {
        if !self.showsComposer {
            self.transcriptView
        } else if self.layoutStrategy.usesDetachedComposer {
            VStack(spacing: 0) {
                self.transcriptView
                ProgressCardView(store: self.store)
                Composer(
                    store: self.store,
                    allowsSending: self.allowsSending,
                    focused: self.$composerFocused)
                    .equatable()
            }
        } else {
            self.transcriptView
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        ProgressCardView(store: self.store)
                        Composer(
                            store: self.store,
                            allowsSending: self.allowsSending,
                            focused: self.$composerFocused)
                            .equatable()
                    }
                }
        }
    }

    var body: some View {
        self.transcriptAndComposer
        .toolbar {
            ToolbarItem { Button("Questions", systemImage: "questionmark.bubble") { showingQuestions = true } }
            ToolbarItem { Button("Secure entry", systemImage: "key") { showingSecretRequests = true } }
        }
        .sheet(isPresented: $showingQuestions) { QuestionInboxView(store: store) }
        .sheet(isPresented: $showingSecretRequests) { SecretRequestsView(store: store) }
        .onChange(of: showingFind) { _, _ in refreshFindMatches() }
        .onChange(of: store.transcriptRevision) { _, _ in refreshFindMatches() }
        .onChange(of: showAgentWork) { _, _ in refreshFindMatches() }
        .onChange(of: store.selectedSessionKey) { _, _ in
            navigation.reset(); navigationJumpVersion += 1; topVisibleItemID = nil; findQuery = ""; findIndex = -1
            showingFind = false; findMatches = []; navigationNotice = nil
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
            ConnectionStatusView(store: store)
            navigationControls
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let pending = store.questionInbox.sorted.filter { $0.request.isPending(at: context.date) }
                if !pending.isEmpty {
                    Button("\(pending.count) question\(pending.count == 1 ? "" : "s") waiting", systemImage: "questionmark.bubble.fill") { showingQuestions = true }
                        .padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
            if store.secretRequests.contains(where: { $0.isPendingSecret && $0.belongs(to: store.selectedSessionKey) }) {
                Button("A secure credential is requested — enter privately", systemImage: "lock.fill") { showingSecretRequests = true }
                    .padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
            }

            if focusedSearchItemID != nil {
                HStack {
                    Text("Viewing another part of the conversation").font(.caption)
                    Spacer()
                    Button("Latest") { focusedSearchItemID = nil; followState.resume(); scrollToBottom() }
                }.padding(10).background(.regularMaterial)
            }
            if store.searchFocusMessageID != nil, let excerpt = store.searchFocusExcerpt,
               SessionKeyMatcher.matches(store.searchFocusSessionKey, store.selectedSessionKey) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Search match").font(.caption.weight(.semibold))
                        Text(excerpt).font(.caption).lineLimit(3).textSelection(.enabled)
                        Text("Cast will jump to this message if it is in the loaded transcript. Older session versions may only be available in search.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Dismiss") { store.searchFocusMessageID = nil; store.searchFocusExcerpt = nil }
                }.padding(10).background(.regularMaterial)
            }
            if case let .stale(message, retryScheduled) = self.store.historySyncState {
                HistorySyncBanner(message: message, retryScheduled: retryScheduled) {
                    self.store.retryHistoryNow()
                }
            }
            }
            .background(Theme.canvas)
        }
        .navigationTitle(self.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Toggle("Show agent's work", isOn: self.$showAgentWork)
                } label: {
                    Label(
                        self.showAgentWork ? "Showing agent's work" : "Showing just the answer",
                        systemImage: self.showAgentWork ? "eye" : "eye.slash")
                }
                .help(self.showAgentWork ? "Hide agent work" : "Show agent work")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    self.showingLibrary = true
                } label: {
                    Label("Library", systemImage: "photo.on.rectangle.angled")
                }
                .help("Media and links from this chat")
            }
        }
        .sheet(isPresented: self.$showingLibrary) {
            LibraryView(store: self.store)
        }
        .quickLookPreview(self.$previewURL)
        .environment(\.openURL, OpenURLAction { url in
            guard DocumentLink.intercepts(url) else { return .systemAction }
            guard let key = self.store.selectedSessionKey,
                  let link = DocumentLink(url: url, sessionKey: key) else { return .discarded }
            self.documentLink = link
            return .handled
        })
        .sheet(item: self.$documentLink) { link in
            DocumentLinkView(link: link, store: self.store)
        }
    }

    private var currentFindMatchID: String? { findMatches.indices.contains(findIndex) ? findMatches[findIndex] : nil }
    private func refreshFindMatches() {
        let previous = currentFindMatchID
        findMatches = showingFind ? TranscriptNavigation.matches(items, query: findQuery) : []
        findIndex = previous.flatMap { findMatches.firstIndex(of: $0) } ?? -1
    }

    private func rememberReadingPlace() {
        navigation.remember(followState.followsLatest ? .latest : .item(topVisibleItemID ?? visibleItems.first?.id ?? "streaming"))
    }
    private func jump(to id: String) {
        navigationJumpVersion += 1
        let version = navigationJumpVersion
        let session = store.selectedSessionKey
        navigationNotice = nil
        if id == "streaming" {
            focusedSearchItemID = nil; readingWindowStartID = nil; readingWindowEndID = nil; transcriptWindow.reset()
        } else if items.contains(where: { $0.id == id }) {
            focusedSearchItemID = id
        } else { navigationNotice = "That reading place is no longer in the loaded conversation."; return }
        followState.scrollPhaseChanged(userDriven: true, isNearBottom: false)
        nearBottom = false; atBottom = false
        Task { @MainActor in
            await Task.yield()
            guard session == store.selectedSessionKey, version == navigationJumpVersion else { return }
            scrollPosition.scrollTo(id: id, anchor: .top)
        }
    }
    private func find(_ offset: Int) {
        let matches = findMatches
        guard !matches.isEmpty else { return }
        rememberReadingPlace()
        findIndex = findIndex < 0 ? (offset < 0 ? matches.count - 1 : 0) : (findIndex + offset + matches.count) % matches.count
        jump(to: matches[findIndex])
    }
    @ViewBuilder private var navigationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    Button("Latest reply", systemImage: "bubble.left") {
                        if let id = TranscriptNavigation.latestReply(items) { rememberReadingPlace(); jump(to: id) }
                    }.disabled(TranscriptNavigation.latestReply(items) == nil)
                    Button("Active work", systemImage: "waveform.path.ecg") {
                        rememberReadingPlace(); showAgentWork = true; jump(to: "streaming")
                    }.disabled(!store.isAgentTurnActive)
                    Button("Latest", systemImage: "arrow.down.to.line") {
                        rememberReadingPlace(); followState.resume(); scrollToBottom()
                    }
                } label: { Label("Jump to", systemImage: "arrow.up.arrow.down") }
                Button("Find", systemImage: "magnifyingglass") { showingFind.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
                Spacer()
                if navigation.returnPlace != nil {
                    Button("Back to reading", systemImage: "arrow.uturn.backward") {
                        switch navigation.takeReturn() {
                        case .latest: followState.resume(); scrollToBottom()
                        case .item(let id): jump(to: id)
                        case nil: break
                        }
                    }
                }
            }.font(.caption).buttonStyle(.borderless)
            if showingFind {
                HStack {
                    TextField("Find in loaded conversation", text: $findQuery)
                        .textFieldStyle(.roundedBorder).onSubmit { find(1) }
                        .onChange(of: findQuery) { _, _ in findIndex = -1; refreshFindMatches() }
                    Text(findQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 ? "2+ characters" : findMatches.isEmpty ? "No matches" : findIndex < 0 ? "\(findMatches.count) matches" : "\(min(findIndex + 1, findMatches.count))/\(findMatches.count)\(findMatches.count == 200 ? "+" : "")")
                        .font(.caption).monospacedDigit()
                    Button("Previous match", systemImage: "chevron.up") { find(-1) }.labelStyle(.iconOnly).disabled(findMatches.isEmpty)
                    Button("Next match", systemImage: "chevron.down") { find(1) }.labelStyle(.iconOnly).disabled(findMatches.isEmpty)
                }
                Text("Searches loaded message groups. Use workspace Search for older history.").font(.caption2).foregroundStyle(.secondary)
            }
            if let navigationNotice { Text(navigationNotice).font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 12).padding(.vertical, 8).background(.regularMaterial)
    }

    @ViewBuilder
    private var emptyTranscriptView: some View {
        if case .loading = self.store.historySyncState {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading conversation…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            ContentUnavailableView(
                "No messages yet",
                systemImage: "bubble.left",
                description: Text("Send a message to start this conversation."))
        }
    }

    @ViewBuilder
    private func itemView(_ item: TranscriptItem) -> some View {
        switch item {
        case let .daySeparator(_, date):
            DaySeparatorView(date: date)
        case let .toolRun(run):
            ToolRunView(run: run, isExpanded: self.expandedRuns.contains(run.id)) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if self.expandedRuns.contains(run.id) {
                        self.expandedRuns.remove(run.id)
                    } else {
                        self.expandedRuns.insert(run.id)
                    }
                }
            }
            .equatable()
        case let .group(group):
            MessageGroupView(
                group: group,
                agentName: self.store.agentDisplayName,
                agentIdentity: self.store.agentIdentity,
                gatewayURL: self.store.profile.gatewayURL,
                workspaceID: self.store.profile.id,
                agentID: self.store.selectedAgentID,
                onOpenMedia: { url in self.previewURL = url },
                onRetrySend: { messageID in self.store.retrySend(messageID: messageID) },
                downloadAttachment: { [sessionKey = self.store.selectedSessionKey] attachment in
                    guard let sessionKey else { throw ArtifactTransferError.unavailable }
                    return try await self.store.fetchDeliverable(attachment.deliverable(sessionKey: sessionKey))
                })
                .equatable()
        }
    }
}

private struct HistorySyncBanner: View {
    let message: String
    let retryScheduled: Bool
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.orange)
            Text(self.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(self.retryScheduled ? "Retry now" : "Retry", action: self.retry)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

private struct LiveTranscriptTail: View {
    let store: ChatStore
    let showAgentWork: Bool
    let allowsSending: Bool

    private var turnPresentation: AgentTurnPresentation {
        AgentTurnPresentation(
            isActive: self.store.isAgentTurnActive,
            showDetails: self.showAgentWork,
            assistantText: self.store.streamingText,
            reasoningText: self.store.streamingReasoningText,
            toolName: self.store.activeToolName,
            workItems: self.store.activeWorkItems)
    }

    var body: some View {
        if self.turnPresentation.shouldRender {
            StreamingView(
                presentation: self.turnPresentation,
                agentName: self.store.agentDisplayName,
                agentIdentity: self.store.agentIdentity,
                gatewayURL: self.store.profile.gatewayURL,
                workspaceID: self.store.profile.id,
                agentID: self.store.selectedAgentID,
                // The Stop affordance rides the same anchor as "Thinking…": it exists
                // exactly as long as a turn the operator might want to kill exists.
                onStop: self.allowsSending && self.store.isAgentTurnActive && !self.store.isAbortingRun
                    ? { self.store.abortActiveRun() }
                    : nil)
                .id("streaming")
        }
    }
}

struct StreamingView: View {
    let presentation: AgentTurnPresentation
    let agentName: String
    let agentIdentity: AgentIdentity?
    let gatewayURL: URL
    let workspaceID: String
    let agentID: String
    /// Aborts the active run. Optional so read-only surfaces can omit the Stop affordance.
    var onStop: (() -> Void)?
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !self.presentation.visibleAssistantText.isEmpty {
                AgentHeader(
                    name: self.agentName,
                    identity: self.agentIdentity,
                    gatewayURL: self.gatewayURL,
                    workspaceID: self.workspaceID,
                    agentID: self.agentID,
                    date: nil)
                MarkdownBody(text: self.presentation.visibleAssistantText).equatable()
            }
            if !self.presentation.visibleReasoningText.isEmpty {
                Text(self.presentation.visibleReasoningText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ForEach(self.presentation.visibleWorkItems) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.isComplete ? "checkmark.circle" : "gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.caption.weight(.medium))
                        if let detail = item.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            if self.presentation.showsActivityIndicator {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.tint)
                        .opacity(self.pulsing ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: self.pulsing)
                    Text(self.presentation.statusLabel)
                        .font(.caption)
                        .fontDesign(.rounded)
                        .foregroundStyle(.secondary)
                    if let onStop = self.onStop {
                        Button(action: onStop) {
                            Label("Stop", systemImage: "stop.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Stop the running turn")
                        .accessibilityLabel("Stop the running turn")
                    }
                }
                .onAppear { self.pulsing = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Composer: View, Equatable {
    let store: ChatStore
    var allowsSending = true
    /// Owned by `ChatView`: the detached composer resizes the transcript's actual frame, so
    /// the transcript has to know when the keyboard arrives in order to re-anchor.
    @FocusState.Binding var focused: Bool
    @State private var model: ComposerModel
    private let storeIdentity: ObjectIdentifier
    @State private var draft = ""
    @State private var importing = false
    @State private var importTarget: ChatStore.AttachmentDraftTarget?
    @State private var confirmingDelivery = false
    @State private var dropTargeted = false
    @StateObject private var voiceRecorder = VoiceRecorderController()
    @StateObject private var dictation = LocalDictation()
    @AppStorage("dictationCorrections") private var dictationCorrections = DictationDraft.defaultCorrections
    @Environment(\.scenePhase) private var composerScenePhase
    #if os(macOS)
    @StateObject private var desktopAccess = DesktopAccess()
    @State private var showingDictationSetup = false
    @State private var showingDesktopPicker = false
    #endif
    #if os(macOS)
    @State private var pasteMonitor: Any?
    @State private var measuredTextHeight: CGFloat = 18
    #endif

    init(
        store: ChatStore,
        allowsSending: Bool = true,
        focused: FocusState<Bool>.Binding)
    {
        self.store = store
        self.allowsSending = allowsSending
        self._focused = focused
        self._model = State(wrappedValue: ComposerModel(store: store))
        self.storeIdentity = ObjectIdentifier(store)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storeIdentity == rhs.storeIdentity && lhs.allowsSending == rhs.allowsSending
    }
    #if os(iOS)
    @State private var pasteboardHasImages = false
    @State private var sendPulse = 0
    @State private var showingPhotos = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var importingMedia = false
    @State private var mediaImportID = UUID()
    @State private var photoImportTask: Task<Void, Never>?
    #endif

    private var sendDisabled: Bool {
        !self.allowsSending || self.dictation.phase != .idle
            || (self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && self.model.pendingAttachments.isEmpty)
    }

    #if os(macOS)
    /// Explicit composer height driven by the field editor's actual laid-out text: one line
    /// minimum, grows with hard newlines AND soft wraps, capped at 12 rows. Beyond that
    /// NSTextView's internal scroll takes over so the transcript never gets pushed up.
    private var macOSComposerHeight: CGFloat {
        let lineHeight: CGFloat = 18
        let maxRows: CGFloat = 12
        let insets = ComposerNSTextView.textInset.height * 2
        let usable = max(lineHeight, self.measuredTextHeight)
        let capped = min(usable, lineHeight * maxRows)
        return capped + insets
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            self.inputCard
            ComposerModelIndicator(store: self.store)
                .padding(.horizontal, 16)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 4)
        .onAppear { self.restoreDraft() }
        .onChange(of: self.model.selectedSessionKey) { _, _ in
            // The outgoing session's draft is already persisted keystroke-by-keystroke;
            // only the incoming session's saved text needs to be restored here. A voice
            // capture is context-bound to the chat it was recorded in, so discard it.
            self.restoreDraft()
            self.voiceRecorder.cancel()
            self.dictation.cancel()
            #if os(macOS)
            self.desktopAccess.stop()
            #endif
        }
        .onChange(of: self.draft) { _, text in
            guard let key = self.model.selectedSessionKey else { return }
            self.store.setDraft(text, forSession: key)
        }
        .onChange(of: self.voiceRecorder.failureMessage) { _, message in
            guard let message else { return }
            self.store.showError(message)
            self.voiceRecorder.clearFailureMessage()
        }
        .onChange(of: self.dictation.output) { _, output in
            guard let output else { return }
            defer { self.dictation.output = nil }
            guard output.conversation == self.model.selectedSessionKey else { return }
            self.draft = DictationDraft.inserting(DictationDraft.corrected(output.text, rules: self.dictationCorrections), into: self.draft)
        }
        .onChange(of: self.dictation.failure) { _, error in
            if let error { self.store.showError(error); self.dictation.failure = nil }
        }
        .onChange(of: self.composerScenePhase) { _, phase in
            if phase == .background { self.dictation.cancel() }
        }
        .onDisappear {
            self.voiceRecorder.cancel()
            self.dictation.cancel()
            #if os(macOS)
            self.desktopAccess.stop()
            #endif
        }
        .onDrop(of: [.fileURL, .image], isTargeted: self.$dropTargeted) { providers in
            self.importDroppedProviders(providers)
        }
        #if os(macOS)
        .sheet(isPresented: self.$showingDictationSetup) { DictationSetupView() }
        .sheet(isPresented: self.$showingDesktopPicker) {
            DesktopWindowPicker(access: self.desktopAccess) { window, interact in
                let session = self.model.selectedSessionKey
                Task {
                    do {
                        let attachment = try await self.desktopAccess.begin(window: window, interact: interact, conversation: session ?? "")
                        guard session == self.model.selectedSessionKey else { self.desktopAccess.stop(); return }
                        for existing in self.model.pendingAttachments where existing.fileName == "Cast-window-context.txt" { self.store.removeAttachment(id: existing.id) }
                        self.store.addAttachments([attachment])
                    } catch { self.store.showError(error.localizedDescription) }
                }
            }
        }
        .onAppear { self.installPasteMonitor() }
        .onDisappear {
            if let monitor = self.pasteMonitor {
                NSEvent.removeMonitor(monitor)
                self.pasteMonitor = nil
            }
        }
        #endif
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in self.dictation.cancel() }
        .sensoryFeedback(.impact(weight: .light), trigger: self.sendPulse)
        .photosPicker(
            isPresented: self.$showingPhotos,
            selection: self.$selectedPhotos,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .automatic)
        .onChange(of: self.selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            self.selectedPhotos = []
            self.photoImportTask?.cancel()
            let target = self.store.attachmentDraftTarget
            let importID = UUID()
            self.mediaImportID = importID
            self.photoImportTask = Task { await self.importPhotos(items, target: target, importID: importID) }
        }
        .onChange(of: self.model.selectedSessionKey) { _, _ in
            self.photoImportTask?.cancel()
            self.photoImportTask = nil
        }
        .onDisappear {
            self.photoImportTask?.cancel()
            self.photoImportTask = nil
        }
        .onAppear { self.refreshPasteboardState() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            self.refreshPasteboardState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            self.refreshPasteboardState()
        }
        #endif
        .fileImporter(
            isPresented: self.$importing,
            allowedContentTypes: [.image, .pdf, .plainText, .data],
            allowsMultipleSelection: true)
        { result in
            let target = self.importTarget
            self.importTarget = nil
            if case let .success(urls) = result, let target {
                for url in urls { self.store.addAttachment(url: url, target: target) }
            } else if case let .failure(error) = result { self.store.showError(error.localizedDescription) }
        }
        .confirmationDialog(
            "Deliver this reply through the session's external channel?",
            isPresented: self.$confirmingDelivery,
            titleVisibility: .visible)
        {
            Button("Deliver externally", role: .destructive) { self.performSend(deliver: true) }
            Button("Keep in Cast") { self.performSend(deliver: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This may send the agent's response to iMessage, Telegram, or another linked channel.")
        }
        .alert("Cast", isPresented: Binding(
            get: { self.model.lastError != nil },
            set: { if !$0 { self.store.clearError() } }))
        {
            // context_length is a dead end without this: the one-tap compact turns the
            // failure alert into the fix (sessions.compact, then a history reload).
            if let key = self.model.contextCompactionOfferKey {
                Button("Compact Conversation") { self.store.compactSession(key) }
            }
            Button("OK") { self.store.clearError() }
        } message: {
            Text(self.model.lastError ?? "Unknown error")
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if os(iOS)
            if self.importingMedia {
                ProgressView("Preparing photos and videos…").font(.caption).padding(.horizontal, 8)
            }
            #endif
            if !self.model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(self.model.pendingAttachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                self.store.removeAttachment(id: attachment.id)
                                #if os(macOS)
                                if attachment.fileName == "Cast-window-context.txt" { self.desktopAccess.stop() }
                                #endif
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                }
            }
            if self.dictation.phase != .idle {
                HStack {
                    if self.dictation.phase == .recording { Image(systemName: "record.circle").foregroundStyle(.red) }
                    else { ProgressView().controlSize(.small) }
                    Text(self.dictation.status).font(.caption)
                    Spacer()
                    if self.dictation.phase == .recording { Button("Finish") { self.dictation.finish() } }
                    Button("Cancel") { self.dictation.cancel() }
                }.padding(.horizontal, 12).padding(.top, 8)
            }
            #if os(macOS)
            if let window = self.desktopAccess.activeWindow {
                HStack {
                    Image(systemName: "macwindow")
                    Text("\(window.app_name) · \(self.desktopAccess.mode == "interact" ? "Interaction enabled" : "Inspect only")").font(.caption)
                    Spacer()
                    Button("Stop access", role: .destructive) { self.desktopAccess.stop(); if self.store.isAgentTurnActive { self.store.abortActiveRun() } }
                }.padding(.horizontal, 12).padding(.top, 8)
            }
            #endif
            if self.voiceRecorder.stoppedAtLimit, case .preview = self.voiceRecorder.state {
                VoiceLimitNotice()
            }
            HStack(alignment: .bottom, spacing: 8) {
                if case let .preview(recording) = self.voiceRecorder.state {
                    VoicePreviewRow(
                        recording: recording,
                        onDelete: { self.voiceRecorder.cancel() },
                        onSend: { self.sendVoiceMessage() })
                } else {
                    if self.voiceRecorder.isCapturing {
                        VoiceRecordingIndicator(controller: self.voiceRecorder)
                    } else {
                        self.attachmentAndTextControls
                    }
                    if self.allowsSending {
                        // Kept structurally stable across the idle → recording swap above so
                        // the in-flight hold gesture survives the transition.
                        VoiceRecordButton(controller: self.voiceRecorder)
                            .disabled(self.dictation.phase != .idle)
                            .padding(.vertical, 4)
                    }
                    if !self.voiceRecorder.isCapturing {
                        self.deliveryAndSendControls
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .background(
            GlassCapsule()
                .overlay {
                    if self.dropTargeted {
                        Capsule().strokeBorder(.tint, lineWidth: 2)
                    }
                })
    }

    @ViewBuilder
    private var attachmentAndTextControls: some View {
        if self.allowsSending {
            Button {
                if self.dictation.phase == .recording { self.dictation.finish() }
                else if let context = self.model.selectedSessionKey { self.dictation.start(context: context) }
            } label: { Image(systemName: "waveform.badge.mic").frame(width: 28, height: 28) }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .disabled(self.dictation.phase == .preparing || self.dictation.phase == .transcribing)
            .help("Dictate into this draft")
            .accessibilityLabel("Dictate into draft")
            .keyboardShortcut("d", modifiers: [.command, .shift])
            #if os(macOS)
            Menu {
                Button("Dictation Setup…") { self.showingDictationSetup = true }
                Button("Attach a Window…") { self.showingDesktopPicker = true }
            } label: { Image(systemName: "macwindow.badge.plus").frame(width: 28, height: 28) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // The composer is bottom-aligned. Size the native menu itself, not
            // just its label, to match the adjacent 28-point tool buttons.
            .frame(height: 28)
            .padding(.vertical, 4)
            .help("Local dictation and desktop agents")
            .disabled(self.dictation.phase != .idle)
            #endif
        }
        #if os(iOS)
        Menu {
            Button(self.importingMedia ? "Preparing media…" : "Photos & Videos", systemImage: "photo.on.rectangle") {
                self.showingPhotos = true
            }.disabled(self.importingMedia)
            Button("Files", systemImage: "folder") {
                self.importTarget = self.store.attachmentDraftTarget; self.importing = true
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .accessibilityLabel("Attach photo or file")
        #else
        Button { self.importTarget = self.store.attachmentDraftTarget; self.importing = true } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .accessibilityLabel("Attach image or file")
        #endif
        #if os(iOS)
        if self.pasteboardHasImages {
            Button { self.importFromUIPasteboard() } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .accessibilityLabel("Paste image from clipboard")
        }
        #endif
        #if os(macOS)
        // NSTextView representable so we control the insets ourselves; a SwiftUI
        // placeholder overlaid at the same origin lines up 1:1 with the caret.
        // Explicit height off the draft (line count) drives the scroll container
        // above a twelve-row ceiling.
        ZStack(alignment: .topLeading) {
            if self.draft.isEmpty {
                Text("Message the fleet…")
                    .foregroundStyle(.secondary)
                    .padding(.leading, ComposerNSTextView.textInset.width)
                    .padding(.top, ComposerNSTextView.textInset.height)
                    .allowsHitTesting(false)
            }
            ComposerNSTextView(
                text: self.$draft,
                onEditingChange: { self.focused = $0 },
                onCommit: { self.sendDraft() },
                onMeasuredHeightChange: { self.measuredTextHeight = $0 })
            .onAppear { self.installDiagnosticDraftIfRequested() }
            .onPasteCommand(of: [.image, .fileURL]) { _ in
                _ = self.importFromGeneralPasteboard()
            }
        }
        .frame(height: self.macOSComposerHeight)
        .animation(.easeOut(duration: 0.12), value: self.macOSComposerHeight)
        #else
        TextField("Message the fleet…", text: self.$draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1 ... 12)
            // Keep the empty field at its intrinsic one-line height inside the
            // detached VStack. It still grows through the line-limit range, and
            // Dynamic Type remains free to increase each line's intrinsic height.
            .fixedSize(horizontal: false, vertical: true)
            .focused(self.$focused)
            .onSubmit { self.sendDraft() }
            .onAppear {
                self.focused = true
                self.installDiagnosticDraftIfRequested()
            }
            .padding(.vertical, 8)
        #endif
    }

    @ViewBuilder
    private var deliveryAndSendControls: some View {
        Button {
            self.store.deliverExternally.toggle()
        } label: {
            Image(systemName: self.model.deliverExternally ? "paperplane.fill" : "paperplane")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(self.model.deliverExternally ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .disabled(!self.allowsSending)
        .help(self.model.deliverExternally ? "External channel delivery enabled" : "Replies stay in Cast")
        .accessibilityLabel(self.model.deliverExternally ? "External delivery enabled" : "External delivery disabled")
        Button(action: self.sendDraft) {
            ZStack {
                Circle()
                    .fill(self.sendDisabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint))
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(self.sendDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .disabled(self.sendDisabled)
        .accessibilityLabel("Send message")
    }

    private func restoreDraft() {
        guard let key = self.model.selectedSessionKey else { return }
        self.draft = self.store.draft(forSession: key)
    }

    private func installDiagnosticDraftIfRequested() {
        #if os(macOS) && DEBUG
        guard self.draft.isEmpty,
              let rawCount = ProcessInfo.processInfo.environment["CAST_COMPOSER_PREFILL_CHARACTERS"],
              let requestedCount = Int(rawCount),
              requestedCount > 0
        else { return }

        let characterCount = min(requestedCount, 200_000)
        let phrase = "Cast layout diagnostic text measurement. "
        let repetitions = (characterCount / phrase.count) + 1
        self.draft = String(String(repeating: phrase, count: repetitions).prefix(characterCount))
        #endif
    }

    private func sendDraft() {
        guard self.allowsSending, self.dictation.phase == .idle else { return }
        guard !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !self.model.pendingAttachments.isEmpty else { return }
        if self.model.deliverExternally {
            self.confirmingDelivery = true
        } else {
            self.performSend(deliver: false)
        }
    }

    /// Promotes the voice preview into a pending attachment and pushes it through the
    /// exact draft/send path images use, so frame validation and the external-delivery
    /// confirmation both still apply.
    private func sendVoiceMessage() {
        do {
            let attachment = try self.voiceRecorder.makeAttachment()
            self.store.addAttachments([attachment])
            self.sendDraft()
        } catch VoiceRecordingError.nothingToAttach {
            // A rapid second tap on Send races the preview → idle reset; the first tap
            // already handled the recording, so there is nothing to report.
        } catch {
            self.store.showError(error.localizedDescription)
        }
    }

    private func performSend(deliver: Bool) {
        guard self.dictation.phase == .idle else { return }
        let text = self.draft
        guard self.store.send(text, deliver: deliver) else { return }
        self.draft = ""
        #if os(iOS)
        self.sendPulse += 1
        // iOS 17+ TextField(axis: .vertical) does not re-render when the binding is
        // cleared while the field is focused — the internal UITextView keeps the sent
        // text visible. Blipping focus on the next runloop forces SwiftUI to rebind and
        // the UITextView picks up the empty string. Refocus immediately so the keyboard
        // does not dismiss between sends.
        self.focused = false
        DispatchQueue.main.async {
            self.focused = true
        }
        #endif
    }

    #if os(iOS)
    private func importPhotos(_ items: [PhotosPickerItem], target: ChatStore.AttachmentDraftTarget, importID: UUID) async {
        var prepared: [PreparedAttachment] = []
        var failures: [String] = []
        self.importingMedia = true
        defer { if self.mediaImportID == importID { self.importingMedia = false } }
        for (index, item) in items.enumerated() {
            guard !Task.isCancelled else { return }
            do {
                if item.supportedContentTypes.contains(where: { VideoAttachments.isVideo($0) }) {
                    guard let video = try await item.loadTransferable(type: PickedVideoAttachment.self) else {
                        throw VideoAttachments.ImportError.invalidVideo
                    }
                    try Task.checkCancellation()
                    prepared.append(video.attachment)
                    continue
                }
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentError.unreadable
                }
                guard !Task.isCancelled else { return }
                let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
                let ext = type?.preferredFilenameExtension ?? "jpg"
                let name = "Photo \(index + 1).\(ext)"
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try AttachmentProcessor.prepareImage(data: data, fileName: name)
                }.value
                guard !Task.isCancelled else { return }
                prepared.append(attachment)
            } catch {
                guard !Task.isCancelled else { return }
                failures.append(error.localizedDescription)
            }
        }
        guard !Task.isCancelled, self.store.attachmentDraftTarget == target else { return }
        if !prepared.isEmpty { self.store.addAttachments(prepared) }
        if let first = failures.first {
            self.store.showError(failures.count == 1 ? first : "\(failures.count) selected items could not be attached. \(first)")
        }
    }
    #endif

    // MARK: - Pasteboard and drag-and-drop import

    #if os(macOS)
    /// SwiftUI's onPasteCommand never fires while the TextField's AppKit field editor is
    /// first responder, so Cmd+V is intercepted app-locally. Returning true consumes the
    /// event (image/file attached); false lets the text view paste text as always.
    /// Enter handling lives in ComposerNSTextView's doCommandBy delegate — the global
    /// monitor's `firstResponder is NSTextView` check missed cases after Shift+Return.
    private func installPasteMonitor() {
        guard self.pasteMonitor == nil else { return }
        self.pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
                return self.importFromGeneralPasteboard() ? nil : event
            }
            return event
        }
    }

    @discardableResult
    private func importFromGeneralPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            for url in urls { self.store.addAttachment(url: url) }
            return true
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            self.store.addAttachment(imageData: data, fileName: "Pasted Image")
            return true
        }
        return false
    }
    #endif

    #if os(iOS)
    private func refreshPasteboardState() {
        self.pasteboardHasImages = UIPasteboard.general.hasImages
    }

    private func importFromUIPasteboard() {
        for image in UIPasteboard.general.images ?? [] {
            guard let data = image.pngData() ?? image.jpegData(compressionQuality: 0.9) else { continue }
            self.store.addAttachment(imageData: data, fileName: "Pasted Image")
        }
    }
    #endif

    private func importDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        let target = self.store.attachmentDraftTarget
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.store.addAttachment(url: url, target: target) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in self.store.addAttachment(imageData: data, fileName: "Dropped Image", target: target) }
                }
            }
        }
        return handled
    }
}

#if os(macOS)
/// AppKit-backed composer field. We drive the insets ourselves so the SwiftUI placeholder
/// overlay can share the exact origin as the caret. NSScrollView + NSTextView gives us a
/// real scroll container above the composer's height cap without extra plumbing.
private struct ComposerNSTextView: NSViewRepresentable {
    @Binding var text: String
    var onEditingChange: (Bool) -> Void
    var onCommit: () -> Void
    var onMeasuredHeightChange: (CGFloat) -> Void

    /// Origin offset from the field's top-left corner where the first glyph lands. The
    /// SwiftUI placeholder uses these same numbers as its leading/top padding so the two
    /// stay pixel-aligned.
    static let textInset = CGSize(width: 5, height: 6)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = MacOSComposerTextView()
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = NSColor.textColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(
            width: Self.textInset.width,
            height: Self.textInset.height)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.string = self.text

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // The text view restores focus on attachment and app/window activation.
        DispatchQueue.main.async {
            context.coordinator.reportMeasuredHeight()
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != self.text {
            textView.string = self.text
            DispatchQueue.main.async {
                context.coordinator.reportMeasuredHeight()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerNSTextView
        weak var textView: NSTextView?
        private var lastReportedHeight: CGFloat = -1

        init(_ parent: ComposerNSTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let performanceInterval = CastPerformanceDiagnostics.begin(
                .composerKeystroke,
                metadata: "characters=\(textView.textStorage?.length ?? 0)")
            defer { CastPerformanceDiagnostics.end(performanceInterval) }
            self.parent.text = textView.string
            self.reportMeasuredHeight()
        }

        func textDidBeginEditing(_ notification: Notification) {
            self.parent.onEditingChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            self.parent.onEditingChange(false)
        }

        /// Intercept Return semantics inside the field editor itself. The app-wide key
        /// monitor previously handled this, but its `firstResponder is NSTextView` check
        /// missed cases (e.g. right after Shift+Return moved focus internally), so Enter
        /// silently no-op'd instead of sending. Doing it here can't miss.
        ///
        /// Behavior:
        ///   Return              → send draft
        ///   Shift+Return        → newline (arrives as insertNewline:; AppKit has no
        ///                         separate Shift+Return binding, so check the live
        ///                         event's modifier flags)
        ///   Option/Ctrl+Return  → newline (insertLineBreak: / insertNewlineIgnoringFieldEditor:)
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    self.reportMeasuredHeight()
                    return true
                }
                self.parent.onCommit()
                return true
            case #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                self.reportMeasuredHeight()
                return true
            default:
                return false
            }
        }

        /// Measure the field editor's used rect and report height only when it materially
        /// changes, so the SwiftUI parent doesn't re-render on every keystroke.
        func reportMeasuredHeight() {
            guard let textView = self.textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let rounded = ceil(used)
            if abs(rounded - self.lastReportedHeight) < 0.5 { return }
            self.lastReportedHeight = rounded
            self.parent.onMeasuredHeightChange(rounded)
        }
    }
}
#endif

/// Pending-attachment chip: real thumbnail for images, filename + size for files.
struct AttachmentChip: View {
    let attachment: PreparedAttachment
    let onRemove: () -> Void

    private var thumbnail: Image? {
        guard self.attachment.type == "image" else { return nil }
        #if os(macOS)
        guard let image = NSImage(data: self.attachment.data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: self.attachment.data) else { return nil }
        return Image(uiImage: image)
        #endif
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(self.attachment.byteCount), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail = self.thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: self.attachment.mimeType.hasPrefix("video/") ? "video.fill" : (self.attachment.type == "audio" ? "waveform" : "doc"))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(self.attachment.fileName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(self.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(action: self.onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(self.attachment.fileName)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attachment \(self.attachment.fileName), \(self.sizeText)")
    }
}

/// Liquid Glass chrome on OS 26, system material fallback on macOS 15 (PRD 5.1).
/// Rounded-rectangle instead of a true capsule: at a single line the corner radius reads
/// as pill-shaped, but at multi-line heights it stays a clean rounded rect instead of
/// pinching to squashed hemispheres at the top and bottom.
struct GlassCapsule: View {
    private static let cornerRadius: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        if #available(iOS 26.0, macOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(.regularMaterial)
                .overlay(shape.strokeBorder(.quaternary, lineWidth: 0.5))
        }
    }
}

/// Session metadata updates independently of the field editor and streamed transcript.
private struct ComposerModelIndicator: View {
    let store: ChatStore
    @State private var settingsSession: String?

    private var isConnected: Bool {
        if case .connected = self.store.connectionState { return true }
        return false
    }

    var body: some View {
        let session = self.store.sessions.first { $0.key == self.store.selectedSessionKey }
        let status = ComposerModelStatus(
            model: session?.model,
            isConnected: self.isConnected)
        Button {
            self.settingsSession = self.store.selectedSessionKey
        } label: {
            HStack(spacing: 5) {
                Text(status.label)
                if let key = self.store.selectedSessionKey, self.store.pendingModelChanges[key] != nil {
                    Text("· next turn").foregroundStyle(.orange)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
        }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(status.label)
            .help("Model settings. " + status.help)
            .sheet(isPresented: Binding(get: { self.settingsSession != nil }, set: { if !$0 { self.settingsSession = nil } })) {
                if let key = self.settingsSession { SessionModelSettingsView(store: self.store, sessionKey: key) }
            }
    }
}

#if os(macOS)
/// Observe only real scroll input delivered to this transcript's window and bounds.
/// Never consume the event: native scrolling, momentum and accessibility remain AppKit's.
private struct TranscriptWheelObserver: NSViewRepresentable {
    let onWheel: (Bool) -> Void

    func makeNSView(context: Context) -> WheelView { WheelView(onWheel: self.onWheel) }
    func updateNSView(_ view: WheelView, context: Context) { view.onWheel = self.onWheel }
    static func dismantleNSView(_ view: WheelView, coordinator: ()) { view.stop() }

    final class WheelView: NSView {
        var onWheel: (Bool) -> Void
        private var monitor: Any?

        init(onWheel: @escaping (Bool) -> Void) {
            self.onWheel = onWheel
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.stop()
            guard self.window != nil else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.type == .keyDown {
                    // Keyboard navigation belongs to the transcript only when its responder
                    // is inside these bounds, never while typing in the detached composer.
                    guard let responder = window.firstResponder as? NSView,
                          self.bounds.intersects(self.convert(responder.bounds, from: responder)),
                          [49, 115, 116, 119, 121, 125, 126].contains(Int(event.keyCode))
                    else { return event }
                    self.onWheel(
                        (event.keyCode == 49 && event.modifierFlags.contains(.shift))
                            || ![49, 119, 121, 125].contains(Int(event.keyCode)))
                } else {
                    guard self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                    if event.type == .scrollWheel, event.scrollingDeltaY != 0 {
                        self.onWheel(event.scrollingDeltaY > 0)
                    } else if event.type == .leftMouseDown,
                              let content = window.contentView,
                              content.hitTest(content.convert(event.locationInWindow, from: nil)) is NSScroller {
                        self.onWheel(true)
                    }
                }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            self.monitor = nil
        }
        deinit { self.stop() }
    }
}
#endif
