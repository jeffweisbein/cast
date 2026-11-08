import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PreparedAttachment: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let type: String
    public let mimeType: String
    public let fileName: String
    public let data: Data
    public let fileURL: URL?
    public let fileSize: Int?
    public let sha256: String?

    public init(id: UUID = UUID(), type: String, mimeType: String, fileName: String, data: Data) {
        self.id = id
        self.type = type
        self.mimeType = mimeType
        self.fileName = fileName
        self.data = data
        self.fileURL = nil
        self.fileSize = nil
        self.sha256 = nil
    }

    init(id: UUID, type: String, mimeType: String, fileName: String, fileURL: URL, size: Int, sha256: String) {
        self.id = id; self.type = type; self.mimeType = mimeType; self.fileName = fileName
        self.data = Data(); self.fileURL = fileURL; self.fileSize = size; self.sha256 = sha256
    }
    public var byteCount: Int { self.fileSize ?? self.data.count }
    /// Only deletes an application-owned immutable copy, never the source picked by the user.
    func removeOwnedFile() {
        guard let url = fileURL, url.deletingLastPathComponent().standardizedFileURL == AttachmentFiles.root.standardizedFileURL else { return }
        AttachmentFiles.remove(url)
    }


    func inlineRPCValue() throws -> [String: Any?] {
        guard byteCount <= AttachmentProcessor.maxFileBytes else { throw AttachmentError.invalidUpload }
        let bytes: Data
        if let fileURL {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, values.fileSize == byteCount else { throw AttachmentError.unreadable }
            bytes = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard bytes.count == byteCount, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw AttachmentError.unreadable }
        } else { bytes = data }
        return ["type": type, "mimeType": mimeType, "fileName": fileName, "content": bytes.base64EncodedString()]
    }
    public var rpcValue: [String: Any?] { get throws { try inlineRPCValue() } }

}

public enum AttachmentError: Error, LocalizedError, Sendable {
    case unreadable
    case imageDecode
    case imageTooLarge(Int)
    case fileTooLarge(Int)
    case payloadTooLarge(Int)
    case emptyFile
    case tooManyFiles
    case batchTooLarge
    case uploadsUnavailable
    case invalidUpload

    public var errorDescription: String? {
        switch self {
        case .emptyFile: return "Remove empty files before sending a large attachment batch."
        case .tooManyFiles: return "Attach up to 20 files per message."
        case .batchTooLarge: return "Attachments must total 2 GB or less per message."
        case .uploadsUnavailable: return "This gateway needs the large-upload update. Smaller attachments still work; your originals have not been compressed."
        case .invalidUpload: return "The upload could not be verified. Retry to resume your original files."
        case .unreadable: return "Cast could not read that file."
        case .imageDecode: return "That image format could not be decoded."
        case let .imageTooLarge(bytes): return "The image is still too large after compression (\(Self.size(bytes)))."
        case let .fileTooLarge(bytes): return "Files must be 500 MB or smaller (selected: \(Self.size(bytes)))."
        case let .payloadTooLarge(bytes): return "This message would exceed the gateway's 25 MB frame limit (\(Self.size(bytes)))."
        }
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

public enum AttachmentProcessor {
    public static let inlineImageTargetBytes = 1_900_000
    public static let maxFileBytes = 16 * 1024 * 1024
    public static let maxFrameBytes = 24 * 1024 * 1024

    public static func prepareForSending(url: URL, originalFileName: String? = nil, typeIdentifier: String? = nil) async throws -> PreparedAttachment {
        let type = typeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: url.pathExtension)
        if VideoAttachments.isVideo(type) {
            return try await VideoAttachments.prepare(url: url, fileName: originalFileName, typeIdentifier: typeIdentifier)
        }
        return try prepare(url: url, originalFileName: originalFileName, typeIdentifier: typeIdentifier)
    }

    public static func prepare(
        url: URL,
        originalFileName: String? = nil,
        typeIdentifier: String? = nil) throws -> PreparedAttachment
    {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let type = typeIdentifier.flatMap(UTType.init)
            ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) != true,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > inlineImageTargetBytes {
            return try AttachmentFiles.copy(url: url, name: originalFileName ?? url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { throw AttachmentError.unreadable }
        let fileName = originalFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = fileName.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        if type?.conforms(to: .image) == true {
            return try self.prepareImage(data: data, fileName: resolvedName)
        }
        guard data.count <= self.maxFileBytes else { throw AttachmentError.fileTooLarge(data.count) }
        return PreparedAttachment(
            type: "file",
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            fileName: resolvedName,
            data: data)
    }

    public static func prepareImage(data: Data, fileName: String = "Pasted Image") throws -> PreparedAttachment {
        let compressed = try self.compressImage(data)
        return PreparedAttachment(type: "image", mimeType: "image/jpeg", fileName: self.jpegName(fileName), data: compressed)
    }

    public static func validateFrame(message: String, attachments: [PreparedAttachment]) throws {
        try validateBatch(attachments)
        let textBytes = try frameByteCount(message: message, attachments: [])
        guard textBytes <= maxFrameBytes - 65536 else { throw AttachmentError.payloadTooLarge(textBytes) }
        // Large bodies travel as bounded chunks. Only their references enter chat.send.
        if try requiresUpload(message: message, attachments: attachments) {
            guard attachments.allSatisfy({ $0.byteCount > 0 }) else { throw AttachmentError.emptyFile }
            return
        }
        let encodedSize = try frameByteCount(message: message, attachments: attachments)
        guard encodedSize <= self.maxFrameBytes else { throw AttachmentError.payloadTooLarge(encodedSize) }
    }

    public static func validateBatch(_ attachments: [PreparedAttachment]) throws {
        try AttachmentLimits.validate(sizes: attachments.map(\.byteCount))
    }
    public static func requiresUpload(message: String, attachments: [PreparedAttachment]) throws -> Bool {
        if attachments.contains(where: { $0.byteCount > maxFileBytes }) { return true }
        guard !attachments.isEmpty else { return false }
        return try frameByteCount(message: message, attachments: attachments) > maxFrameBytes
    }

    // Count the exact JSON payload without constructing base64 on the UI actor.
    // The gateway encoder uses withoutEscapingSlashes, so base64 has no JSON escapes.
    static func frameByteCount(message: String, attachments: [PreparedAttachment]) throws -> Int {
        let metadata: [[String: String]] = attachments.map {
            ["type": $0.type, "mimeType": $0.mimeType, "fileName": $0.fileName, "content": ""]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let envelope = AnyCodable(["message": "", "attachments": metadata] as [String: Any?])
        var size = try encoder.encode(envelope).count
        for byte in message.utf8 {
            switch byte {
            case 8, 9, 10, 12, 13, 34, 92: size += 2
            case 0..<32: size += 6
            default: size += 1
            }
        }
        return size + attachments.reduce(0) { $0 + (($1.byteCount + 2) / 3) * 4 }
    }

    static func compressImage(_ input: Data, targetBytes: Int = inlineImageTargetBytes) throws -> Data {
        guard let source = CGImageSourceCreateWithData(input as CFData, nil) else { throw AttachmentError.imageDecode }
        var dimension = 2400
        var quality = 0.84
        var smallest: Data?
        while dimension >= 720 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw AttachmentError.imageDecode
            }
            var localQuality = quality
            while localQuality >= 0.48 {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output,
                    UTType.jpeg.identifier as CFString,
                    1,
                    nil)
                else { throw AttachmentError.imageDecode }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: localQuality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw AttachmentError.imageDecode }
                let candidate = output as Data
                if smallest == nil || candidate.count < smallest!.count { smallest = candidate }
                if candidate.count <= targetBytes { return candidate }
                localQuality -= 0.1
            }
            dimension = Int(Double(dimension) * 0.75)
            quality = max(quality - 0.05, 0.65)
        }
        throw AttachmentError.imageTooLarge(smallest?.count ?? input.count)
    }

    private static func jpegName(_ original: String) -> String {
        let base = (original as NSString).deletingPathExtension
        return "\(base.isEmpty ? "image" : base).jpg"
    }
}
