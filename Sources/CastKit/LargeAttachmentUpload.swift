import CryptoKit
import Foundation

public struct AttachmentUploadProgress: Sendable, Equatable {
    public let completedBytes: Int
    public let totalBytes: Int
}

/// No whole-video Data or base64 allocation. The RPC transport sees at most a 1 MiB chunk.
enum LargeAttachmentUpload {
    struct Policy: Decodable {
        let version: Int, maxFileBytes: Int, maxFiles: Int, maxBatchBytes: Int, chunkBytes: Int
        let enabled: Bool
    }
    struct FileState: Decodable { let id: String; let offset: Int; let complete: Bool }
    struct BatchState: Decodable { let batchId: String; let chunkBytes: Int; let files: [FileState] }
    struct ChunkState: Decodable { let fileId: String; let offset: Int; let complete: Bool }
    typealias Request = @Sendable (String, [String: Any?]) async throws -> Data

    static func upload(sessionKey: String, sessionID: String, batchID: String, attachments: [PreparedAttachment],
                       request: Request, progress: @Sendable (AttachmentUploadProgress) -> Void) async throws -> [[String: Any?]] {
        try AttachmentProcessor.validateBatch(attachments)
        guard attachments.allSatisfy({ $0.byteCount > 0 }) else { throw AttachmentError.emptyFile }
        let decoder = JSONDecoder()
        let policy = try decoder.decode(Policy.self, from: await request("chat.upload.policy", [:]))
        guard policy.enabled, policy.version == 1, policy.chunkBytes > 0, policy.chunkBytes <= 1_048_576 else { throw AttachmentError.uploadsUnavailable }
        guard attachments.count <= policy.maxFiles, attachments.allSatisfy({ $0.byteCount <= policy.maxFileBytes }),
              attachments.reduce(0, { $0 + $1.byteCount }) <= policy.maxBatchBytes else { throw AttachmentError.uploadsUnavailable }
        let binding: [String: Any?] = ["sessionKey": sessionKey, "sessionId": sessionID, "batchId": batchID]
        var begin = binding
        begin["files"] = attachments.map { item -> [String: Any?] in
            ["id": item.id.uuidString, "fileName": item.fileName, "mimeType": item.mimeType,
             "sizeBytes": item.byteCount, "sha256": item.sha256 ?? SHA256.hash(data: item.data).map { String(format: "%02x", $0) }.joined()]
        }
        try Task.checkCancellation()
        let state = try decoder.decode(BatchState.self, from: await request("chat.upload.begin", begin))
        guard state.batchId == batchID, state.chunkBytes > 0, state.chunkBytes <= policy.chunkBytes,
              Set(state.files.map(\.id)) == Set(attachments.map { $0.id.uuidString }), state.files.count == attachments.count else { throw AttachmentError.invalidUpload }
        let total = attachments.reduce(0) { $0 + $1.byteCount }
        var sent = 0
        do {
            for item in attachments {
                guard let remote = state.files.first(where: { $0.id == item.id.uuidString }), remote.offset >= 0,
                      remote.offset <= item.byteCount, remote.complete == (remote.offset == item.byteCount) else { throw AttachmentError.invalidUpload }
                var offset = remote.offset
                sent += offset; progress(.init(completedBytes: sent, totalBytes: total))
                let file = try item.fileURL.map { try FileHandle(forReadingFrom: $0) }
                defer { try? file?.close() }
                if let file { try file.seek(toOffset: UInt64(offset)) }
                while offset < item.byteCount {
                    try Task.checkCancellation()
                    let count = min(state.chunkBytes, item.byteCount - offset)
                    let chunk: Data
                    if let file { chunk = try file.read(upToCount: count) ?? Data() }
                    else { chunk = item.data.subdata(in: offset..<(offset + count)) }
                    guard chunk.count == count else { throw AttachmentError.unreadable }
                    var params = binding
                    params["fileId"] = item.id.uuidString; params["offset"] = offset; params["content"] = chunk.base64EncodedString()
                    let ack = try decoder.decode(ChunkState.self, from: await request("chat.upload.chunk", params))
                    guard ack.fileId == item.id.uuidString, ack.offset == offset + count,
                          ack.complete == (ack.offset == item.byteCount) else { throw AttachmentError.invalidUpload }
                    offset = ack.offset; sent += count; progress(.init(completedBytes: sent, totalBytes: total))
                }
            }
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                // Bound cancellation to the exact origin batch. Local sources stay available for retry.
                _ = try? await request("chat.upload.cancel", binding)
                throw CancellationError()
            }
            throw error
        }
        return attachments.map { ["upload": ["batchId": batchID, "fileId": $0.id.uuidString]] }
    }
}
