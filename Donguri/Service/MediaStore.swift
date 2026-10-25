//
//  MediaStore.swift
//  Donguri
//
//  Downloads, caches and decodes the images and videos linked from posts.
//
//  Three layers, checked in order:
//   1. Memory: decoded images, sized for where they're shown (NSCache, so
//      iOS can reclaim it under memory pressure).
//   2. Pinned files (Application Support/SavedMedia): media belonging to
//      threads saved for offline reading. Never trimmed automatically.
//   3. Cached files (Caches/Media): everything else that has been viewed or
//      preloaded, trimmed oldest-first past `cacheLimitBytes`.
//
//  Anything missing is downloaded once; concurrent requests for the same URL
//  share one download.
//

import Foundation
import UIKit
import ImageIO
import AVFoundation
import CryptoKit

actor MediaStore {
    nonisolated static let shared = MediaStore()

    /// The disk cache is trimmed back under this at launch.
    nonisolated static let cacheLimitBytes: Int64 = 1_000_000_000

    /// NSCache is thread-safe, which is what makes reading it from
    /// `nonisolated` code (for an instant, flicker-free cache hit) sound.
    private nonisolated(unsafe) let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 200 * 1024 * 1024
        return cache
    }()

    private let cacheFolder: URL?
    private let pinnedFolder: URL?

    private var inFlight: [URL: Task<URL, Error>] = [:]

    init() {
        let fileManager = FileManager.default
        cacheFolder = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Media", isDirectory: true)
        pinnedFolder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SavedMedia", isDirectory: true)
        for folder in [cacheFolder, pinnedFolder].compactMap({ $0 }) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    // MARK: Files

    /// The local copy of `url`, if it has already been downloaded.
    nonisolated func existingFile(for url: URL) -> URL? {
        let name = Self.fileName(for: url)
        for folder in [pinnedFolder, cacheFolder].compactMap({ $0 }) {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                return file
            }
        }
        return nil
    }

    /// A local copy of `url`, downloading it first if needed.
    func file(for url: URL) async throws -> URL {
        if let existing = existingFile(for: url) {
            Self.touch(existing)
            return existing
        }
        if let running = inFlight[url] {
            return try await running.value
        }
        guard let cacheFolder else { throw URLError(.cannotCreateFile) }

        let destination = cacheFolder.appendingPathComponent(Self.fileName(for: url))
        let task = Task<URL, Error> {
            try await Self.download(url, to: destination)
            return destination
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return try await task.value
    }

    /// Keeps an image that came from the device (a scanned photo, a web page
    /// snapshot) under a made-up URL, so the gallery can show it like any
    /// downloaded image.
    func storeLocal(_ data: Data) -> URL? {
        guard let cacheFolder,
              let url = URL(string: "https://iroha.local/scan/\(UUID().uuidString).jpg") else { return nil }
        let destination = cacheFolder.appendingPathComponent(Self.fileName(for: url))
        do {
            try data.write(to: destination, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Downloads without decoding: used to preload, and by "download all".
    func prefetch(_ url: URL) async -> Bool {
        (try? await file(for: url)) != nil
    }

    /// Makes sure `url` is kept for offline reading.
    func pin(_ url: URL) async throws {
        guard let pinnedFolder else { throw URLError(.cannotCreateFile) }
        let name = Self.fileName(for: url)
        let pinned = pinnedFolder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: pinned.path(percentEncoded: false)) { return }

        let source = try await file(for: url)
        if source != pinned {
            try? FileManager.default.removeItem(at: pinned)
            try FileManager.default.moveItem(at: source, to: pinned)
        }
    }

    /// Releases offline copies; they move back into the ordinary cache.
    func unpin(_ urls: [URL]) {
        guard let pinnedFolder, let cacheFolder else { return }
        for url in urls {
            let name = Self.fileName(for: url)
            let pinned = pinnedFolder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: pinned.path(percentEncoded: false)) else { continue }
            let cached = cacheFolder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: cached)
            try? FileManager.default.moveItem(at: pinned, to: cached)
        }
    }

    // MARK: Images

    /// A decoded image. `maxPixelSize` downsamples (thumbnails); nil gives the
    /// full-size image for the gallery, animated if it's an animated GIF.
    func image(for url: URL, maxPixelSize: CGFloat?) async -> UIImage? {
        let key = Self.memoryKey(url, maxPixelSize)
        if let cached = memory.object(forKey: key) { return cached }
        guard let file = try? await file(for: url) else { return nil }
        guard let image = await Self.decode(file, maxPixelSize: maxPixelSize) else { return nil }
        memory.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    /// Instant memory-only lookup, so a row that scrolls back on screen can
    /// draw its thumbnail in the same frame instead of flashing a spinner.
    nonisolated func memoryImage(for url: URL, maxPixelSize: CGFloat?) -> UIImage? {
        memory.object(forKey: Self.memoryKey(url, maxPixelSize))
    }

    /// A still frame for a video, for thumbnails and the gallery strip.
    func videoThumbnail(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = Self.memoryKey(url, maxPixelSize)
        if let cached = memory.object(forKey: key) { return cached }
        // A cached file is much faster than reading the start of a remote one.
        let source = existingFile(for: url) ?? url
        guard let image = await Self.videoFrame(source, maxPixelSize: maxPixelSize) else { return nil }
        memory.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    /// Thumbnail for either kind of item.
    func thumbnail(for item: MediaItem, maxPixelSize: CGFloat) async -> UIImage? {
        switch item.kind {
        case .image:
            return await image(for: item.url, maxPixelSize: maxPixelSize)
        case .video:
            return await videoThumbnail(for: item.url, maxPixelSize: maxPixelSize)
        case .unsupportedVideo:
            return nil
        }
    }

    // MARK: Cache management

    func cacheSizeBytes() -> (cached: Int64, pinned: Int64) {
        (Self.folderSize(cacheFolder), Self.folderSize(pinnedFolder))
    }

    func clearCache() {
        memory.removeAllObjects()
        guard let cacheFolder else { return }
        try? FileManager.default.removeItem(at: cacheFolder)
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
    }

    /// Deletes the least recently used cached files until the cache fits.
    func trimCache(to limit: Int64 = MediaStore.cacheLimitBytes) {
        guard let cacheFolder,
              let files = try? FileManager.default.contentsOfDirectory(
                at: cacheFolder,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
              ) else { return }

        var entries: [(url: URL, date: Date, size: Int64)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return nil
            }
            return (url: file,
                    date: values.contentModificationDate ?? .distantPast,
                    size: Int64(values.fileSize ?? 0))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }

        entries.sort { $0.date < $1.date }
        for entry in entries where total > limit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: Helpers

    /// `<sha256 of the URL>.<ext>`. The real extension matters: Photos and the
    /// share sheet decide what a file is from it.
    nonisolated static func fileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hash).\(fileExtension(for: url))"
    }

    nonisolated static func fileExtension(for url: URL) -> String {
        let known = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "mp4", "mov", "m4v", "webm"]
        let ext = url.pathExtension.lowercased()
        if known.contains(ext) { return ext }
        // pbs.twimg.com/media/…?format=jpg
        if let format = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "format" })?.value?.lowercased(),
           known.contains(format) {
            return format
        }
        return "jpg"
    }

    private nonisolated static func memoryKey(_ url: URL, _ maxPixelSize: CGFloat?) -> NSString {
        "\(Int(maxPixelSize ?? 0))|\(url.absoluteString)" as NSString
    }

    private nonisolated static func cost(of image: UIImage) -> Int {
        let frames = max(image.images?.count ?? 1, 1)
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels) * 4 * frames
    }

    /// Bumps the file's date so `trimCache` treats it as recently used.
    private nonisolated static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date.now],
                                               ofItemAtPath: file.path(percentEncoded: false))
    }

    private nonisolated static func folderSize(_ folder: URL?) -> Int64 {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder,
                                                                       includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private nonisolated static func download(_ url: URL, to destination: URL) async throws {
        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // Dead image links often answer with an HTML page instead of a 404.
        if let mime = http.mimeType?.lowercased(), mime.hasPrefix("text/") {
            throw URLError(.cannotDecodeContentData)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Decoding happens off the actor so several thumbnails can decode at once.
    @concurrent
    private nonisolated static func decode(_ file: URL, maxPixelSize: CGFloat?) async -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions) else { return nil }

        let frameCount = CGImageSourceGetCount(source)
        if maxPixelSize == nil, frameCount > 1 {
            return animatedImage(from: source, frameCount: frameCount)
        }
        // "Full size" is still capped: big enough to zoom into on any iPhone,
        // small enough that the pages either side fit in memory too. A
        // 12,000px photo would otherwise take half a gigabyte decoded.
        return frame(at: 0, of: source, maxPixelSize: maxPixelSize ?? 2560).map { UIImage(cgImage: $0) }
    }

    private nonisolated static func frame(at index: Int, of source: CGImageSource, maxPixelSize: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private nonisolated static func animatedImage(from source: CGImageSource, frameCount: Int) -> UIImage? {
        // Long GIFs are thinned rather than decoded frame for frame.
        let maxFrames = 240
        let step = max(1, Int((Double(frameCount) / Double(maxFrames)).rounded(.up)))
        let decodedFrames = Double((frameCount + step - 1) / step)
        // Every frame stays decoded while it plays, so the frames are sized
        // to keep the whole animation under a budget: a long, large GIF at
        // full size took hundreds of megabytes and seconds to open.
        let budget = 96.0 * 1024 * 1024
        var side: CGFloat = 1600
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Double,
           let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0 {
            let longest = max(width, height)
            let aspect = min(width, height) / longest
            let allowed = (budget / (decodedFrames * 4 * aspect)).squareRoot()
            side = CGFloat(max(240, min(longest, allowed, 1600)))
        }
        var frames: [UIImage] = []
        var duration: Double = 0

        for index in stride(from: 0, to: frameCount, by: step) {
            guard let cgImage = frame(at: index, of: source, maxPixelSize: side) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            duration += frameDelay(at: index, of: source) * Double(step)
        }
        guard !frames.isEmpty else { return nil }
        if frames.count == 1 { return frames[0] }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    private nonisolated static func frameDelay(at index: Int, of source: CGImageSource) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        let dictionaries = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary]
        for key in dictionaries {
            guard let dictionary = properties[key] as? [CFString: Any] else { continue }
            let unclamped = (dictionary[kCGImagePropertyGIFUnclampedDelayTime]
                             ?? dictionary[kCGImagePropertyAPNGUnclampedDelayTime]
                             ?? dictionary[kCGImagePropertyWebPUnclampedDelayTime]) as? Double
            let clamped = (dictionary[kCGImagePropertyGIFDelayTime]
                           ?? dictionary[kCGImagePropertyAPNGDelayTime]
                           ?? dictionary[kCGImagePropertyWebPDelayTime]) as? Double
            if let delay = unclamped ?? clamped {
                // Browsers treat very short delays as 0.1s; so do we.
                return delay < 0.02 ? 0.1 : delay
            }
        }
        return 0.1
    }

    @concurrent
    private nonisolated static func videoFrame(_ url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard let result = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else {
            return nil
        }
        return UIImage(cgImage: result.image)
    }
}
