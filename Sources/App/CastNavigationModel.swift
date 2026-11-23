import Foundation

/// Primary iOS destinations. Mac keeps its sidebar + toolbar navigation.
enum CastTab: String, CaseIterable, Identifiable, Hashable {
    case chats, needsYou, results
    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .needsYou: return "Needs You"
        case .results: return "Results"
        }
    }

    var systemImage: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .needsYou: return "hand.raised"
        case .results: return "square.grid.2x2"
        }
    }
}

/// Badge counts for the bottom tabs. Each count has exactly one owner so nothing is counted
/// twice: Needs You owns live requests, Results owns unreviewed gateway artifacts.
enum CastNavigationCounts {
    /// Questions, approvals, blockers, failures and failed deliveries. Review items are owned
    /// by Results and excluded here.
    static func needsYou(_ items: [AttentionItem]) -> Int {
        var seen = Set<String>()
        return items.filter { $0.kind != .review && seen.insert($0.id).inserted }.count
    }

    /// Unreviewed gateway artifacts only — the same truth as a chat row's "Ready to review".
    /// Ordinary links in prose never inflate the badge.
    static func results(_ counts: [String: ResultArtifactCounts]) -> Int {
        counts.values.reduce(0) { $0 + max(0, $1.unreviewed) }
    }
}

// MARK: - Pinned quick switcher

struct PinnedSwitcherEntry: Identifiable, Equatable {
    let key: String
    let title: String
    let isSelected: Bool
    let unread: Bool
    let state: ChatWorkState?
    var id: String { self.key }
}

enum PinnedSwitcher {
    /// Pinned chats in the order they are given (the store's pinned-first, user-ranked
    /// order). Never re-sorted by activity, so muscle memory holds.
    static func entries(
        chats: [SessionRow],
        isPinned: (String) -> Bool,
        title: (SessionRow) -> String,
        selectedKey: String?,
        unread: (SessionRow) -> Bool,
        states: [String: ChatWorkState]) -> [PinnedSwitcherEntry]
    {
        var seen = Set<String>()
        return chats.compactMap { row in
            let canonical = SessionKeyMatcher.canonical(row.key)
            guard isPinned(row.key), seen.insert(canonical).inserted else { return nil }
            return PinnedSwitcherEntry(
                key: row.key,
                title: title(row),
                isSelected: selectedKey.map { SessionKeyMatcher.matches($0, row.key) } ?? false,
                unread: unread(row),
                state: states[canonical])
        }
    }
}

// MARK: - Results library

enum ResultKind: String, CaseIterable, Identifiable {
    case image, file, pullRequest, link
    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .image: return "Images"
        case .file: return "Files"
        case .pullRequest: return "Pull requests"
        case .link: return "Links"
        }
    }

    var singular: String {
        switch self {
        case .image: return "Image"
        case .file: return "File"
        case .pullRequest: return "Pull request"
        case .link: return "Link"
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tif", "tiff", "bmp"]

    static func of(_ item: Deliverable) -> ResultKind {
        if item.kind == "Pull request" { return .pullRequest }
        let ext = ResultsLibrary.fileExtension(of: item)
        if item.kind == "Image" || (item.mimeType?.lowercased().hasPrefix("image/") ?? false) || Self.imageExtensions.contains(ext) {
            return .image
        }
        if item.isGatewayArtifact { return .file }
        switch item.kind {
        case "Document", "Package", "Attachment": return .file
        default: return .link
        }
    }
}

struct PullRequestReference: Equatable {
    let owner: String
    let repository: String
    let number: Int
    var display: String { "\(self.owner)/\(self.repository) #\(self.number)" }

    static func parse(_ target: String) -> PullRequestReference? {
        guard let url = URL(string: target),
              ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0 else { return nil }
        return PullRequestReference(owner: parts[0], repository: parts[1], number: number)
    }
}

enum ResultsLibraryPhase: Equatable {
    enum EmptyReason: Equatable { case none, offline, unsupported }
    case loading
    case content
    case empty(EmptyReason)
    case failed(String)
}

enum ResultsLibrary {
    static func fileExtension(of item: Deliverable) -> String {
        let candidates = [item.title, item.target]
        for value in candidates {
            let path = URL(string: value)?.path ?? value
            let ext = (path as NSString).pathExtension.lowercased()
            // Real extensions only: "v1.2 notes" must not read as a "2 notes" file type.
            if !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return ext }
        }
        return ""
    }

    /// Newest first; ties broken by id so the grid never reshuffles between refreshes.
    static func items(_ ledger: [Deliverable], kind: ResultKind?, query: String) -> [Deliverable] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return ledger.filter { item in
            guard seen.insert(item.reviewID).inserted else { return false }
            if let kind, ResultKind.of(item) != kind { return false }
            return needle.isEmpty || (item.title + " " + item.kind + " " + item.target).localizedCaseInsensitiveContains(needle)
        }.sorted { ($0.sharedAt ?? 0, $0.id) > ($1.sharedAt ?? 0, $1.id) }
    }

    static func counts(_ ledger: [Deliverable]) -> [ResultKind: Int] {
        var result: [ResultKind: Int] = [:]
        var seen = Set<String>()
        for item in ledger where seen.insert(item.reviewID).inserted { result[ResultKind.of(item), default: 0] += 1 }
        return result
    }

    /// Cached items always win: a failed or offline refresh never hides what this device knows.
    static func phase(itemCount: Int, syncing: Bool, hasSynced: Bool, syncError: String?,
                      supportsArtifacts: Bool, connected: Bool) -> ResultsLibraryPhase
    {
        if itemCount > 0 { return .content }
        if syncing && !hasSynced { return .loading }
        if !connected { return .empty(.offline) }
        if let syncError, supportsArtifacts { return .failed(syncError) }
        if !supportsArtifacts && hasSynced { return .empty(.unsupported) }
        if !hasSynced { return .loading }
        return .empty(.none)
    }

    static func systemImage(for item: Deliverable) -> String {
        switch ResultKind.of(item) {
        case .image: return "photo"
        case .pullRequest: return "arrow.triangle.pull"
        case .link: return item.kind == "Release" ? "shippingbox" : "link"
        case .file:
            switch Self.fileExtension(of: item) {
            case "pdf": return "doc.richtext"
            case "md", "txt": return "doc.plaintext"
            case "csv", "xlsx": return "tablecells"
            case "pptx": return "rectangle.on.rectangle"
            case "zip", "dmg", "tar", "gz", "ipa": return "archivebox"
            case "html": return "globe"
            case "json", "patch", "diff", "swift", "py": return "curlybraces"
            default: return item.kind == "Package" ? "archivebox" : "doc"
            }
        }
    }

    /// Small, honest subtitle: PR reference, link host, or type + size.
    static func subtitle(for item: Deliverable) -> String {
        switch ResultKind.of(item) {
        case .pullRequest:
            return PullRequestReference.parse(item.target)?.display ?? "Pull request"
        case .link:
            return item.webURL?.host ?? item.kind
        case .image, .file:
            let ext = Self.fileExtension(of: item).uppercased()
            let type = ext.isEmpty ? item.kind : ext
            guard let size = item.sizeBytes, size > 0 else { return type }
            return type + " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
    }
}
