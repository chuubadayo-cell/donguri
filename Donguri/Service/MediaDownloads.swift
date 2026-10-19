//
//  MediaDownloads.swift
//  Donguri
//
//  Bulk media work with visible progress: "download all images" in a thread,
//  keeping a saved thread's images for offline reading, and saving to Photos.
//

import Foundation
import Network
import Photos
import SwiftUI
import UIKit

/// Whether the current connection is metered (cellular, Personal Hotspot, or
/// Low Data Mode), for the "Wi-Fi only" preload setting.
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isExpensive = false
    private(set) var isConnected = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { @Sendable path in
            let expensive = path.isExpensive || path.isConstrained
            let connected = path.status == .satisfied
            Task { @MainActor in
                NetworkMonitor.shared.update(expensive: expensive, connected: connected)
            }
        }
        monitor.start(queue: DispatchQueue(label: "donguri.network-monitor"))
    }

    private func update(expensive: Bool, connected: Bool) {
        if isExpensive != expensive { isExpensive = expensive }
        if isConnected != connected { isConnected = connected }
    }
}

/// Progress of one bulk job, shown as a banner in the thread or gallery.
@Observable
final class MediaJob {
    nonisolated enum Action: Sendable {
        /// Download into the cache.
        case download
        /// Download and keep for offline reading.
        case pin
        /// Download and add to the photo library.
        case saveToPhotos
    }

    private(set) var total = 0
    private(set) var completed = 0
    private(set) var failed = 0
    private(set) var isRunning = false
    private(set) var action: Action = .download
    /// Set when the job ended because Photos access was refused.
    private(set) var photosDenied = false

    private var task: Task<Void, Never>?

    var progressText: String {
        switch action {
        case .download:
            String(localized: "画像をダウンロード中 \(completed + failed)/\(total)")
        case .pin:
            String(localized: "オフライン用に画像を保存中 \(completed + failed)/\(total)")
        case .saveToPhotos:
            String(localized: "写真に保存中 \(completed + failed)/\(total)")
        }
    }

    var summaryText: String {
        if photosDenied {
            return String(localized: "写真へのアクセスが許可されていません")
        }
        switch action {
        case .download, .pin:
            return failed == 0
                ? String(localized: "\(completed)件の画像を保存しました")
                : String(localized: "\(completed)件を保存・\(failed)件は読み込めませんでした")
        case .saveToPhotos:
            return failed == 0
                ? String(localized: "\(completed)件を写真に保存しました")
                : String(localized: "\(completed)件を写真に保存・\(failed)件は失敗しました")
        }
    }

    /// Runs `action` over `items`, a few at a time.
    func start(_ action: Action, items: [MediaItem], onFinish: ((MediaJob) -> Void)? = nil) {
        cancel()
        let items = action == .saveToPhotos ? items.filter { $0.kind != .unsupportedVideo } : items
        guard !items.isEmpty else { return }

        self.action = action
        total = items.count
        completed = 0
        failed = 0
        photosDenied = false
        isRunning = true

        task = Task { [weak self] in
            if action == .saveToPhotos {
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    self?.photosDenied = true
                    self?.finish(onFinish)
                    return
                }
            }

            await withTaskGroup(of: Bool.self) { group in
                var next = 0
                let width = action == .saveToPhotos ? 2 : 4

                func addNext() {
                    guard next < items.count else { return }
                    let item = items[next]
                    next += 1
                    group.addTask {
                        await MediaJob.perform(action, on: item)
                    }
                }

                for _ in 0..<width { addNext() }

                for await succeeded in group {
                    guard let self, !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    if succeeded { self.completed += 1 } else { self.failed += 1 }
                    addNext()
                }
            }

            self?.finish(onFinish)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func finish(_ onFinish: ((MediaJob) -> Void)?) {
        isRunning = false
        task = nil
        onFinish?(self)
    }

    private nonisolated static func perform(_ action: Action, on item: MediaItem) async -> Bool {
        do {
            switch action {
            case .download:
                _ = try await MediaStore.shared.file(for: item.url)
            case .pin:
                try await MediaStore.shared.pin(item.url)
            case .saveToPhotos:
                let file = try await MediaStore.shared.file(for: item.url)
                try await PhotoSaver.save(file: file, isVideo: item.isVideo)
            }
            return true
        } catch {
            return false
        }
    }
}

nonisolated enum PhotoSaver {
    /// Formats Photos takes as-is. Anything else (WebP, BMP) is re-encoded.
    private static let directFormats: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "mp4", "mov", "m4v"]

    static func save(file: URL, isVideo: Bool) async throws {
        let ext = file.pathExtension.lowercased()
        if directFormats.contains(ext) {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
            }
        } else {
            guard !isVideo,
                  let data = try? Data(contentsOf: file),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.95) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: jpeg, options: nil)
            }
        }
    }
}

/// Preloads thumbnails a little ahead of the scroll position, and, when the
/// setting asks for it, everything in the thread. Deliberately not
/// observable: it only starts downloads, so nothing should redraw when it
/// changes.
final class NearbyPrefetcher {
    /// How many posts below a newly visible row get their thumbnails loaded.
    private static let lookahead = 25

    private var requestedThrough = -1
    private var allTask: Task<Void, Never>?

    func reset() {
        requestedThrough = -1
        allTask?.cancel()
        allTask = nil
    }

    func rowAppeared(_ index: Int, mediaByPost: [Int: [MediaItem]]) {
        guard MediaPrefetchMode.current != .off else { return }
        let end = index + Self.lookahead
        guard end > requestedThrough else { return }
        let start = max(index, requestedThrough + 1)
        requestedThrough = end

        let items = (start...end).flatMap { mediaByPost[$0] ?? [] }
        guard !items.isEmpty else { return }
        let size = MediaThumbnailView.rowPixelSize
        Task.detached(priority: .utility) {
            await NearbyPrefetcher.loadThumbnails(items, size: size)
        }
    }

    func prefetchAll(_ items: [MediaItem]) {
        allTask?.cancel()
        let images = items.filter { $0.kind == .image }
        guard !images.isEmpty else { return }
        let size = MediaThumbnailView.rowPixelSize
        allTask = Task.detached(priority: .utility) {
            await NearbyPrefetcher.loadThumbnails(images, size: size)
        }
    }

    /// Four at a time: quick, without starving what's on screen.
    private nonisolated static func loadThumbnails(_ items: [MediaItem], size: CGFloat) async {
        var index = 0
        while index < items.count, !Task.isCancelled {
            let batch = items[index..<min(index + 4, items.count)]
            index += batch.count
            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    group.addTask {
                        _ = await MediaStore.shared.thumbnail(for: item, maxPixelSize: size)
                    }
                }
            }
        }
    }
}

/// Which gallery to show, set by `ThreadView`.
struct GalleryRequest: Identifiable {
    let id = UUID()
    let startIndex: Int
    let showGrid: Bool
}

extension Transaction {
    /// The gallery fades itself in and out; this keeps the system's
    /// slide-up animation for full-screen covers out of the way.
    static var noAnimation: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }
}
