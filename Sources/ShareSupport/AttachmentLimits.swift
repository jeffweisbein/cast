import Foundation

/// Shared by the containing app and share extension. Decimal byte limits match the receiver.
public enum AttachmentLimits {
    public static let maxFileBytes = 500_000_000
    public static let maxFiles = 20
    public static let maxBatchBytes = 2_000_000_000
    public static func validate(sizes: [Int]) throws {
        guard sizes.count <= maxFiles else { throw LimitError.count }
        guard sizes.allSatisfy({ $0 >= 0 && $0 <= maxFileBytes }) else { throw LimitError.file }
        guard sizes.reduce(Int64(0), { $0 + Int64($1) }) <= maxBatchBytes else { throw LimitError.batch }
    }
    public enum LimitError: Error, LocalizedError {
        case count, file, batch
        public var errorDescription: String? {
            switch self {
            case .count: return "Attach up to 20 files per message."
            case .file: return "Each attachment must be 500 MB or smaller."
            case .batch: return "Attachments must total 2 GB or less per message."
            }
        }
    }
}
