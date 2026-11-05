import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AgentAvatarCacheKey: Hashable, Sendable {
    let workspaceID: String
    let agentID: String
    let url: URL
}

private struct AgentAvatarLoadID: Hashable {
    let workspaceID: String
    let agentID: String
    let gatewayURL: URL
    let rawAvatar: String?
}

actor AgentAvatarDataCache {
    static let shared = AgentAvatarDataCache()
    private var values: [AgentAvatarCacheKey: Data] = [:]
    private var recency: [AgentAvatarCacheKey] = []
    private let capacity: Int

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    func data(for key: AgentAvatarCacheKey) async throws -> Data {
        if let cached = self.cachedData(for: key) { return cached }
        var request = URLRequest(url: key.url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 12
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.mimeType?.lowercased().hasPrefix("image/") == true,
              http.url.map(AgentAvatarSource.isAllowedRemoteURL) == true,
              response.expectedContentLength <= Int64(AgentAvatarSource.maximumBytes)
        else { throw URLError(.badServerResponse) }
        var data = Data()
        data.reserveCapacity(max(0, Int(response.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < AgentAvatarSource.maximumBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        self.insert(data, for: key)
        return data
    }

    func cachedData(for key: AgentAvatarCacheKey) -> Data? {
        guard let cached = self.values[key] else { return nil }
        self.touch(key)
        return cached
    }

    func insert(_ data: Data, for key: AgentAvatarCacheKey) {
        self.values[key] = data
        self.touch(key)
        while self.recency.count > self.capacity, let oldest = self.recency.first {
            self.recency.removeFirst()
            self.values[oldest] = nil
        }
    }

    private func touch(_ key: AgentAvatarCacheKey) {
        self.recency.removeAll { $0 == key }
        self.recency.append(key)
    }
}

struct AgentAvatarView: View {
    let identity: AgentIdentity?
    let fallbackName: String
    let gatewayURL: URL
    let workspaceID: String
    let agentID: String
    @State private var loadedData: Data?
    @State private var loadFailed = false

    private var source: AgentAvatarSource? {
        AgentAvatarSource.resolve(self.identity?.avatar, gatewayURL: self.gatewayURL)
    }

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: [.orange, .red.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing))
            if let image = self.platformImage {
                image.resizable().scaledToFill()
            } else {
                self.fallback
            }
        }
        .clipShape(Circle())
        .task(id: AgentAvatarLoadID(
            workspaceID: self.workspaceID,
            agentID: self.agentID,
            gatewayURL: self.gatewayURL,
            rawAvatar: self.identity?.avatar))
        {
            await self.loadAvatar()
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fallback: some View {
        switch AgentIdentityFallback.choice(
            identityName: self.identity?.name,
            emoji: self.identity?.emoji,
            fallbackName: self.fallbackName)
        {
        case let .initials(initials):
            Text(initials)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        case let .emoji(emoji):
            Text(emoji).font(.system(size: 12))
        case .sparkle:
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var platformImage: Image? {
        guard !self.loadFailed, let data = self.loadedData, Self.hasSafePixelDimensions(data) else { return nil }
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }

    @MainActor
    private func loadAvatar() async {
        self.loadedData = nil
        self.loadFailed = false
        guard let source = self.source else { return }
        do {
            switch source {
            case let .data(data): self.loadedData = data
            case let .remote(url):
                self.loadedData = try await AgentAvatarDataCache.shared.data(for: AgentAvatarCacheKey(
                    workspaceID: self.workspaceID,
                    agentID: self.agentID,
                    url: url))
            }
        } catch {
            self.loadFailed = true
        }
    }

    private static func hasSafePixelDimensions(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return false }
        let widthValue = width.intValue
        let heightValue = height.intValue
        guard widthValue > 0, heightValue > 0, widthValue <= 4096, heightValue <= 4096 else { return false }
        return widthValue * heightValue <= 16_777_216
    }
}
