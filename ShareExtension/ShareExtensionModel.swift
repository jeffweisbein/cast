#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareExtensionModel: ObservableObject {
    @Published private(set) var destinations: ShareDestinationSnapshot
    @Published private(set) var items: [SharedItemInput] = []
    @Published var selectedWorkspaceID: String
    @Published var selectedSessionKey: String
    @Published var message = ""
    @Published private(set) var isLoading = true
    @Published private(set) var isSending = false
    @Published private(set) var status: String?
    @Published private(set) var errorMessage: String?

    private weak var extensionContext: NSExtensionContext?
    private let destinationStore: ShareDestinationStore?
    private var stagedFileURLs: Set<URL> = []
    private var payloadLoadFailed = false

    init(extensionContext: NSExtensionContext?) {
        self.extensionContext = extensionContext
        let store = ShareDestinationStore.appGroup
        self.destinationStore = store
        let snapshot = store?.load()
            ?? ShareDestinationSnapshot(workspaces: [], selectedWorkspaceID: nil)
        self.destinations = snapshot
        let selection = ShareDestinationResolver.resolve(
            snapshot: snapshot,
            recent: store?.loadRecentSelection())
        self.selectedWorkspaceID = selection?.workspaceID ?? ""
        self.selectedSessionKey = selection?.sessionKey ?? ""
        Task { await self.loadItems() }
    }

    var selectedWorkspace: ShareWorkspaceDestination? {
        self.destinations.workspaces.first(where: { $0.id == self.selectedWorkspaceID })
    }

    var selectedSession: ShareSessionDestination? {
        self.availableSessions.first(where: { $0.key == self.selectedSessionKey })
    }

    var availableSessions: [ShareSessionDestination] {
        self.selectedWorkspace?.sessions ?? []
    }

    var canSend: Bool {
        !self.isLoading
            && !self.isSending
            && !self.payloadLoadFailed
            && self.selectedSession != nil
            && (!self.items.isEmpty || !self.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var itemSummary: String {
        guard !self.items.isEmpty else { return self.isLoading ? "Reading shared items…" : "No shared items" }
        let images = self.items.filter { $0.kind == .image }.count
        let files = self.items.filter { $0.kind == .file }.count
        let links = self.items.filter { $0.kind == .url }.count
        let texts = self.items.filter { $0.kind == .text }.count
        return [
            images > 0 ? "\(images) image\(images == 1 ? "" : "s")" : nil,
            files > 0 ? "\(files) file\(files == 1 ? "" : "s")" : nil,
            links > 0 ? "\(links) link\(links == 1 ? "" : "s")" : nil,
            texts > 0 ? "\(texts) text item\(texts == 1 ? "" : "s")" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    func selectWorkspace(_ id: String) {
        self.selectedWorkspaceID = id
        let recent = self.destinationStore?.loadRecentSelection()
        if let recent,
           recent.workspaceID == id,
           self.availableSessions.contains(where: { $0.key == recent.sessionKey }) {
            self.selectedSessionKey = recent.sessionKey
        } else if let preferred = self.selectedWorkspace?.preferredSessionKey,
                  self.availableSessions.contains(where: { $0.key == preferred }) {
            self.selectedSessionKey = preferred
        } else {
            self.selectedSessionKey = self.availableSessions.first?.key ?? ""
        }
    }

    func cancel() {
        self.cleanupStagedFiles()
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        self.extensionContext?.cancelRequest(withError: error)
    }

    func submit() {
        guard self.canSend else { return }
        let selection = ShareDestinationSelection(
            workspaceID: self.selectedWorkspaceID,
            sessionKey: self.selectedSessionKey)
        guard ShareDestinationResolver.contains(selection, in: self.destinations) else {
            self.errorMessage = "That Cast destination is no longer available. Reopen the share sheet and choose another."
            return
        }
        guard let inbox = ShareInbox.appGroup else {
            self.errorMessage = ShareInboxError.appGroupUnavailable.localizedDescription
            return
        }
        self.isSending = true
        self.errorMessage = nil
        do {
            _ = try inbox.enqueue(
                workspaceID: selection.workspaceID,
                sessionKey: selection.sessionKey,
                message: self.message,
                items: self.items)
            self.destinationStore?.remember(selection)
            self.cleanupStagedFiles()
            let destinationName = [self.selectedWorkspace?.name, self.selectedSession?.name]
                .compactMap { $0 }
                .joined(separator: " · ")
            self.status = "Queued for \(destinationName). Open Cast to send."
            self.completeAfterQueueing()
        } catch {
            self.isSending = false
            self.errorMessage = error.localizedDescription
        }
    }

    private func completeAfterQueueing() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func cleanupStagedFiles() {
        for url in self.stagedFileURLs { try? FileManager.default.removeItem(at: url) }
        self.stagedFileURLs.removeAll()
    }

    private func loadItems() async {
        let extensionItems = self.extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        guard providers.count <= 10 else {
            self.isLoading = false
            self.payloadLoadFailed = true
            self.errorMessage = "Cast supports up to 10 shared items at a time. Nothing has been queued."
            return
        }
        // Provider order is payload order. Loading one representation at a
        // time also avoids a ten-file share spiking extension memory.
        var loaded: [SharedItemInput] = []
        var loadedProviderCount = 0
        for extensionItem in extensionItems {
            if let contentText = extensionItem.attributedContentText?.string
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !contentText.isEmpty {
                loaded.append(SharedItemInput(kind: .text, text: contentText))
            }
            for provider in extensionItem.attachments ?? [] {
                if let item = await Self.load(provider) {
                    loadedProviderCount += 1
                    let isDuplicateText = item.kind == .text
                        && loaded.contains(where: { $0.kind == .text && $0.text == item.text })
                    if !isDuplicateText { loaded.append(item) }
                }
            }
        }
        self.items = loaded
        self.stagedFileURLs = Set(loaded.compactMap(\.sourceFileURL))
        self.isLoading = false
        let unreadCount = providers.count - loadedProviderCount
        if unreadCount > 0 {
            self.payloadLoadFailed = true
            self.errorMessage = unreadCount == 1
                ? "Cast couldn’t read one shared item. Nothing has been queued."
                : "Cast couldn’t read \(unreadCount) shared items. Nothing has been queued."
        } else if loaded.isEmpty, self.message.isEmpty {
            self.payloadLoadFailed = true
            self.errorMessage = "Cast couldn’t read the shared item."
        }
    }

    nonisolated private static func load(_ provider: NSItemProvider) async -> SharedItemInput? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let file = await self.loadFileURL(provider) {
            return SharedItemInput(
                kind: file.type.conforms(to: .image) ? .image : .file,
                sourceFileURL: file.url,
                fileName: file.name,
                typeIdentifier: file.type.identifier)
        }

        // Photos can advertise a still preview alongside a movie. Prefer the actual movie.
        for identifier in provider.registeredTypeIdentifiers where UTType(identifier)?.conforms(to: .movie) == true {
            let type = UTType(identifier) ?? .movie
            let name = self.fileName(suggested: provider.suggestedName, fallbackBase: "Shared Video", type: type)
            guard let url = await self.loadStagedFile(provider, typeIdentifier: identifier, fileName: name) else {
                return nil // Never silently send a poster image when the movie could not be read.
            }
            return SharedItemInput(kind: .file, sourceFileURL: url, fileName: name, typeIdentifier: identifier)
        }

        for identifier in self.imageTypeIdentifiers(for: provider) {
            let type = UTType(identifier) ?? .image
            let name = self.fileName(
                suggested: provider.suggestedName,
                fallbackBase: "Shared Image",
                type: type)
            if let url = await self.loadStagedFile(provider, typeIdentifier: identifier, fileName: name) {
                return SharedItemInput(
                    kind: .image,
                    sourceFileURL: url,
                    fileName: name,
                    typeIdentifier: identifier)
            }
            if let data = await self.loadData(provider, typeIdentifier: identifier) {
                guard let url = self.stage(data: data, fileName: name) else { return nil }
                return SharedItemInput(
                    kind: .image,
                    sourceFileURL: url,
                    fileName: name,
                    typeIdentifier: identifier)
            }
        }

        // A freshly captured screenshot can arrive as a UIKit object provider
        // (`com.apple.uikit.image`) without a loadable encoded representation.
        // Preserve screenshot fidelity with PNG and fall back to JPEG only when
        // UIKit cannot encode the image losslessly.
        if provider.canLoadObject(ofClass: UIImage.self),
           let encoded = await self.loadUIImageData(provider)
        {
            let name = self.fileName(
                suggested: provider.suggestedName,
                fallbackBase: "Shared Image",
                type: encoded.type)
            guard let url = self.stage(data: encoded.data, fileName: name) else { return nil }
            return SharedItemInput(
                kind: .image,
                sourceFileURL: url,
                fileName: name,
                typeIdentifier: encoded.type.identifier)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let value = await self.loadValue(provider, typeIdentifier: UTType.url.identifier) {
            if let url = value as? URL, !url.isFileURL {
                return SharedItemInput(kind: .url, text: url.absoluteString)
            }
            if let text = value as? String,
               let url = URL(string: text),
               !url.isFileURL {
                return SharedItemInput(kind: .url, text: text)
            }
        }

        for identifier in self.fileTypeIdentifiers(for: provider) {
            let type = UTType(identifier) ?? .data
            let name = self.fileName(
                suggested: provider.suggestedName,
                fallbackBase: "Shared File",
                type: type)
            if let url = await self.loadStagedFile(provider, typeIdentifier: identifier, fileName: name) {
                return SharedItemInput(
                    kind: .file,
                    sourceFileURL: url,
                    fileName: name,
                    typeIdentifier: identifier)
            }
            if let data = await self.loadData(provider, typeIdentifier: identifier) {
                guard let url = self.stage(data: data, fileName: name) else { return nil }
                return SharedItemInput(
                    kind: .file,
                    sourceFileURL: url,
                    fileName: name,
                    typeIdentifier: identifier)
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let value = await self.loadValue(provider, typeIdentifier: UTType.plainText.identifier) {
            if let text = value as? String { return SharedItemInput(kind: .text, text: text) }
            if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
                return SharedItemInput(kind: .text, text: text)
            }
        }
        return nil
    }

    nonisolated private static func imageTypeIdentifiers(for provider: NSItemProvider) -> [String] {
        var identifiers = provider.registeredTypeIdentifiers.filter { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }
        if identifiers.isEmpty,
           provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            identifiers.append(UTType.image.identifier)
        }
        return identifiers
    }

    nonisolated private static func fileTypeIdentifiers(for provider: NSItemProvider) -> [String] {
        provider.registeredTypeIdentifiers.filter { identifier in
            guard let type = UTType(identifier) else { return false }
            return !type.conforms(to: .image)
                && !type.conforms(to: .url)
                && !type.conforms(to: .plainText)
                && (type.conforms(to: .content) || type.conforms(to: .data))
        }
    }

    nonisolated private static func fileName(
        suggested: String?,
        fallbackBase: String,
        type: UTType) -> String
    {
        let trimmed = suggested?.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = (trimmed?.isEmpty == false ? trimmed : nil) ?? fallbackBase
        if URL(fileURLWithPath: name).pathExtension.isEmpty,
           let ext = type.preferredFilenameExtension {
            name += ".\(ext)"
        }
        return URL(fileURLWithPath: name).lastPathComponent
    }

    nonisolated private static func loadData(_ provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    nonisolated private static func loadUIImageData(
        _ provider: NSItemProvider) async -> (data: Data, type: UTType)?
    {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else {
                    continuation.resume(returning: nil)
                    return
                }
                if let data = image.pngData() {
                    continuation.resume(returning: (data, .png))
                } else if let data = image.jpegData(compressionQuality: 0.92) {
                    continuation.resume(returning: (data, .jpeg))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static func loadValue(_ provider: NSItemProvider, typeIdentifier: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    nonisolated private static func loadFileURL(
        _ provider: NSItemProvider) async -> (url: URL, name: String, type: UTType)?
    {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let source = item as? URL else {
                    continuation.resume(returning: nil)
                    return
                }
                let type = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType)
                    ?? UTType(filenameExtension: source.pathExtension)
                    ?? .data
                let name = self.fileName(
                    suggested: suggestedName ?? source.lastPathComponent,
                    fallbackBase: "Shared File",
                    type: type)
                let staged = self.stage(source: source, fileName: name)
                continuation.resume(returning: staged.map { ($0, name, type) })
            }
        }
    }

    nonisolated private static func loadStagedFile(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        fileName: String) async -> URL?
    {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { source, _ in
                continuation.resume(returning: source.flatMap { self.stage(source: $0, fileName: fileName) })
            }
        }
    }

    nonisolated private static func stage(source: URL, fileName: String) -> URL? {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastShareStaging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = URL(fileURLWithPath: fileName).pathExtension
            let storedName = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
            let destination = directory.appendingPathComponent(storedName)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    nonisolated private static func stage(data: Data, fileName: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastShareStaging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = URL(fileURLWithPath: fileName).pathExtension
            let storedName = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
            let destination = directory.appendingPathComponent(storedName)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }
}
#endif
