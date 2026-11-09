import Foundation

/// Small, evidence-backed projections. Never infer repository ownership from a bare SHA.
public struct CommitReference: Identifiable, Equatable, Sendable {
    public let url: URL
    public let repository: String
    public let hash: String
    public var id: String { url.absoluteString }
    public var shortHash: String { String(hash.prefix(7)) }

    public static func references(in markdown: String) -> [Self] {
        // Links in code examples are not navigation affordances.
        let prose = markdown.components(separatedBy: "```").enumerated()
            .filter { $0.offset.isMultiple(of: 2) }.map(\.element).joined(separator: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/commit/([a-fA-F0-9]{7,40})(?![A-Za-z0-9])"#) else { return [] }
        let source = prose as NSString
        var seen = Set<String>()
        return regex.matches(in: prose, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let address = source.substring(with: match.range)
            guard seen.insert(address).inserted, let url = URL(string: address) else { return nil }
            return Self(url: url, repository: source.substring(with: match.range(at: 1)), hash: source.substring(with: match.range(at: 2)))
        }.prefix(8).map { $0 }
    }
}

public struct DiffSummary: Equatable, Sendable {
    public let additions: Int
    public let deletions: Int
    public let files: [String]
    public init(_ patch: String) {
        let lines = patch.components(separatedBy: .newlines)
        additions = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        deletions = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        var paths: [String] = []
        var oldPath: String?
        for line in lines {
            if line.hasPrefix("--- ") {
                oldPath = line.hasPrefix("--- a/") ? String(line.dropFirst(6)).components(separatedBy: "\t")[0] : nil
            } else if line.hasPrefix("+++ ") {
                let path = line.hasPrefix("+++ b/") ? String(line.dropFirst(6)).components(separatedBy: "\t")[0] : oldPath
                if let path, !paths.contains(path) { paths.append(path) }
                oldPath = nil
            }
        }
        files = paths
    }
}
