import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Preserve original video bytes. Large files use immutable disk-backed upload sources.
/// All representations still use the existing bounded, retry-safe file attachment transport.
public enum VideoAttachments {
    public enum ImportError: Error, LocalizedError {
        case invalidVideo
        public var errorDescription: String? {
            switch self {
            case .invalidVideo: return "Cast couldn’t read that video. Try exporting it as an MP4 or MOV file."
            }
        }
    }

    public static func isVideo(_ type: UTType?) -> Bool {
        type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
    }

    public static func prepare(url: URL, fileName: String? = nil, typeIdentifier: String? = nil) async throws -> PreparedAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw ImportError.invalidVideo }
        try Task.checkCancellation()
        return try AttachmentProcessor.prepare(url: url, originalFileName: fileName, typeIdentifier: typeIdentifier)

    }
}

#if os(iOS)
import CoreTransferable

/// File representation avoids loading a full camera video into memory before size checks.
struct PickedVideoAttachment: Transferable {
    let attachment: PreparedAttachment
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cast-picker-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let copy = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return try await Self(attachment: VideoAttachments.prepare(url: copy))
        }
    }
}
#endif
