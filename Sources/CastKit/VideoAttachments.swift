import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Keep video bytes intact when they fit; otherwise export a smaller copy, never a thumbnail.
/// All representations still use the existing bounded, retry-safe file attachment transport.
public enum VideoAttachments {
    public enum ImportError: Error, LocalizedError {
        case invalidVideo
        case tooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidVideo: return "Cast couldn’t read that video. Try exporting it as an MP4 or MOV file."
            case .tooLarge: return "This video is still over 16 MB after compression. Trim the clip in Photos and try again."
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
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size <= AttachmentProcessor.maxFileBytes {
            return try AttachmentProcessor.prepare(url: url, originalFileName: fileName, typeIdentifier: typeIdentifier)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cast-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, preset) in [AVAssetExportPreset1280x720, AVAssetExportPreset640x480].enumerated() {
            try Task.checkCancellation()
            guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let output = directory.appendingPathComponent("video-\(index).mp4")
            exporter.shouldOptimizeForNetworkUse = true
            exporter.fileLengthLimit = Int64(AttachmentProcessor.maxFileBytes)
            do {
                try await withTaskCancellationHandler {
                    try await exporter.export(to: output, as: .mp4)
                } onCancel: {
                    exporter.cancelExport()
                }
            } catch {
                try Task.checkCancellation()
                if index == 0 { continue }
                throw ImportError.tooLarge
            }
            try Task.checkCancellation()
            let exportedSize = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if exportedSize > 0, exportedSize <= AttachmentProcessor.maxFileBytes {
                let name = ((fileName ?? url.lastPathComponent) as NSString).deletingPathExtension + ".mp4"
                return try AttachmentProcessor.prepare(url: output, originalFileName: name, typeIdentifier: UTType.mpeg4Movie.identifier)
            }
        }
        throw ImportError.tooLarge
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
