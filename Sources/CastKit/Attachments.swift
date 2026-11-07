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

    public init(id: UUID = UUID(), type: String, mimeType: String, fileName: String, data: Data) {
        self.id = id
        self.type = type
        self.mimeType = mimeType
        self.fileName = fileName
        self.data = data
    }

    public var byteCount: Int { self.data.count }

    public var rpcValue: [String: Any?] {
        [
            "type": self.type,
            "mimeType": self.mimeType,
            "fileName": self.fileName,
            "content": self.data.base64EncodedString(),
        ]
    }
}

public enum AttachmentError: Error, LocalizedError, Sendable {
    case unreadable
    case imageDecode
    case imageTooLarge(Int)
    case fileTooLarge(Int)
    case payloadTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Cast could not read that file."
        case .imageDecode: return "That image format could not be decoded."
        case let .imageTooLarge(bytes): return "The image is still too large after compression (\(Self.size(bytes)))."
        case let .fileTooLarge(bytes): return "Files must be 16 MB or smaller (selected: \(Self.size(bytes)))."
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
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileBytes {
            throw AttachmentError.fileTooLarge(size)
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
        // Match the gateway client's JSONEncoder, including quotes, control characters,
        // filenames and escaped base64 slashes. Leave 1 MB for request metadata.
        let payload = AnyCodable(["message": message, "attachments": attachments.map(\.rpcValue)] as [String: Any?])
        let encodedSize = try JSONEncoder().encode(payload).count
        guard encodedSize <= self.maxFrameBytes else { throw AttachmentError.payloadTooLarge(encodedSize) }
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
