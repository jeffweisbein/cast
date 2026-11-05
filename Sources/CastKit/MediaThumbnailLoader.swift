// Cast — bounded thumbnail decode (ImageIO downsample + NSCache) so a 200-message
// transcript full of images stays smooth. Full-size previews go through temp file URLs
// for the system Quick Look viewer.
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public final class MediaThumbnailLoader: @unchecked Sendable {
    public static let shared = MediaThumbnailLoader()

    private let cache = NSCache<NSString, CGImage>()

    public init(countLimit: Int = 300) {
        self.cache.countLimit = countLimit
    }

    /// Downsampled thumbnail for a media item; nil when the path is unreadable on this
    /// machine (remote workspace) and no local bytes exist.
    public func thumbnail(for item: MediaItem, maxPixel: Int) async -> CGImage? {
        let key = "\(item.id)|\(maxPixel)" as NSString
        if let hit = self.cache.object(forKey: key) { return hit }
        #if DEBUG
        let isOfflineLayoutStress = ProcessInfo.processInfo.environment["CAST_OFFLINE_LAYOUT_STRESS"] == "1"
        #else
        let isOfflineLayoutStress = false
        #endif
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            let source: CGImageSource?
            if isOfflineLayoutStress, let data = item.localData {
                // The app-level fixture must never probe gateway paths or touch the network.
                source = CGImageSourceCreateWithData(data as CFData, nil)
            } else if let path = item.path {
                let url = Self.resolvedFileURL(for: path)
                if FileManager.default.isReadableFile(atPath: url.path) {
                    source = CGImageSourceCreateWithURL(url as CFURL, nil)
                } else if let data = item.localData {
                    source = CGImageSourceCreateWithData(data as CFData, nil)
                } else {
                    source = nil
                }
            } else if let data = item.localData {
                source = CGImageSourceCreateWithData(data as CFData, nil)
            } else {
                source = nil
            }
            guard let source else { return nil }
            return Self.downsample(source: source, maxPixel: maxPixel)
        }.value
        #if DEBUG
        if isOfflineLayoutStress {
            // Force a post-placement transition from the 180x130 placeholder to the
            // decoded image's wide/tall aspect ratio. Without this bounded delay, tiny
            // fixture images can decode before SwiftUI commits the placeholder frame.
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        #endif
        if let image { self.cache.setObject(image, forKey: key) }
        return image
    }

    /// A file URL suitable for Quick Look: the gateway path when readable, otherwise the
    /// local echo bytes staged into a temp file.
    public func previewURL(for item: MediaItem) async -> URL? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CAST_OFFLINE_LAYOUT_STRESS"] == "1" {
            // Quick Look staging writes local bytes to disk. The offline fixture disables
            // that path entirely; it only needs the real row's async height resolution.
            return nil
        }
        #endif
        return await Task.detached(priority: .userInitiated) {
            Self.previewURLSync(for: item)
        }.value
    }

    static func resolvedFileURL(for path: String) -> URL {
        if let url = URL(string: path), url.isFileURL { return url.standardizedFileURL }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    private static func previewURLSync(for item: MediaItem) -> URL? {
        if let path = item.path {
            let url = Self.resolvedFileURL(for: path)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        guard let data = item.localData else { return nil }
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CastPreviews", isDirectory: true)
        let url = directory.appendingPathComponent("\(digest).jpg")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return url
    }

    static func downsample(source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
