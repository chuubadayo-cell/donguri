//
//  MangaReading.swift
//  Donguri
//
//  What the manga reader is handed: a run of reading units (a source's
//  chapters, or a title's mokuro volumes) and how to load each unit's
//  pages. A page loads its own image and may bring its text (mokuro);
//  pages without text are read by MangaOCR in the reader.
//

import Foundation
import UIKit
import ImageIO
import AidokuRunner

/// One chapter or volume.
struct ReaderUnit: Identifiable, Hashable {
    /// Where its reading position is kept (MangaLibrary).
    let id: String
    let label: String
}

struct ReaderPage: Identifiable {
    /// Also the key its OCR is kept under.
    let id: String
    let load: () async throws -> UIImage
    /// mokuro's text, already placed on the page.
    var text: PageText?
}

struct ReaderRequest: Identifiable {
    let id = UUID()
    /// The manga's title, which becomes the card's document title.
    let title: String
    /// In reading order (first chapter first).
    let units: [ReaderUnit]
    let startIndex: Int
    /// What the source says (webtoons scroll down), before the user's
    /// own choice for the title.
    var suggestedMode: MangaReadingMode?
    /// The title, for a reading mode chosen for it alone.
    var seriesID: String?
    /// The manga this belongs to, to remember its last chapter.
    var mangaID: String?
    let pages: (ReaderUnit) async throws -> [ReaderPage]
}

enum MangaReaderError: LocalizedError {
    case noPages
    case textPages

    var errorDescription: String? {
        switch self {
        case .noPages: String(localized: "ページがありません")
        case .textPages: String(localized: "文章だけの章には対応していません")
        }
    }
}

// MARK: - Building requests

extension ReaderRequest {
    /// A source's chapters, from `chapter` on. Sources list chapters newest
    /// first; the reader wants them in reading order.
    static func source(_ source: AidokuRunner.Source, manga: AidokuRunner.Manga,
                       chapters: [AidokuRunner.Chapter], start chapter: AidokuRunner.Chapter) -> ReaderRequest {
        let ordered = Array(chapters.filter { !$0.locked }.reversed())
        let byID = Dictionary(ordered.map { (MangaLibrary.chapterID(source: source.key, manga: manga.key, chapter: $0.key), $0) },
                              uniquingKeysWith: { first, _ in first })
        let units = ordered.map {
            ReaderUnit(id: MangaLibrary.chapterID(source: source.key, manga: manga.key, chapter: $0.key),
                       label: $0.displayTitle)
        }
        let startID = MangaLibrary.chapterID(source: source.key, manga: manga.key, chapter: chapter.key)
        let mode: MangaReadingMode? = switch manga.viewer {
        case .leftToRight: .leftToRight
        case .vertical, .webtoon: .vertical
        case .rightToLeft: .rightToLeft
        default: nil
        }
        let mangaID = MangaLibrary.mangaID(source: source.key, manga: manga.key)
        return ReaderRequest(title: manga.title,
                             units: units,
                             startIndex: units.firstIndex { $0.id == startID } ?? 0,
                             suggestedMode: mode,
                             seriesID: mangaID,
                             mangaID: mangaID) { unit in
            guard let chapter = byID[unit.id] else { throw MangaReaderError.noPages }
            let pages = try await source.getPageList(manga: manga, chapter: chapter)
            if pages.isEmpty { throw MangaReaderError.noPages }
            if pages.allSatisfy({ if case .text = $0.content { true } else { false } }) {
                throw MangaReaderError.textPages
            }
            return pages.enumerated().compactMap { index, page in
                let id = "\(unit.id)#\(index)"
                switch page.content {
                case .url(let url, let context):
                    return ReaderPage(id: id) {
                        try await MangaImages.sourcePage(url: url, context: context, source: source, cacheKey: id)
                    }
                case .image(let image):
                    return ReaderPage(id: id) { image }
                case .text, .zipFile:
                    return nil
                }
            }
        }
    }

    /// The books of a series in the Manga folder.
    static func local(_ series: LocalSeries, start: LocalVolume) -> ReaderRequest {
        let units = series.volumes.map { ReaderUnit(id: $0.unitID, label: $0.title) }
        let byID = Dictionary(series.volumes.map { ($0.unitID, $0) }, uniquingKeysWith: { first, _ in first })
        return ReaderRequest(title: series.title,
                             units: units,
                             startIndex: series.volumes.firstIndex(of: start) ?? 0,
                             seriesID: "local\u{1F}\(series.id)") { unit in
            guard let volume = byID[unit.id] else { throw MangaReaderError.noPages }
            let book = LocalBook(volume: volume)
            let names = try await book.open()
            let texts = await MangaImages.mokuroText(for: volume, book: book, pageNames: names)
            return names.indices.map { index in
                ReaderPage(id: "\(unit.id)#\(index)",
                           load: { try await MangaImages.localPage(book, index: index, cacheKey: "\(unit.id)#\(index)") },
                           text: texts?[index])
            }
        }
    }

    /// Volumes served from a web address, all those in the same listing.
    static func remote(title: String, volumes: [(name: String, url: URL)], start: URL) -> ReaderRequest {
        let units = volumes.map { ReaderUnit(id: "mokuro-web\u{1F}\($0.url.absoluteString)", label: $0.name) }
        let byID = Dictionary(units.map(\.id).enumerated().map { ($0.element, volumes[$0.offset].url) },
                              uniquingKeysWith: { first, _ in first })
        return ReaderRequest(title: title,
                             units: units,
                             startIndex: volumes.firstIndex { $0.url == start } ?? 0,
                             seriesID: "mokuro-web\u{1F}\(start.deletingLastPathComponent().absoluteString)") { unit in
            guard let url = byID[unit.id] else { throw MangaReaderError.noPages }
            let mokuro = try await MokuroRemote.volume(at: url)
            return mokuroPages(mokuro, unit: unit, images: url.deletingPathExtension())
        }
    }

    private static func mokuroPages(_ volume: MokuroVolume, unit: ReaderUnit, images: URL) -> [ReaderPage] {
        volume.pages.enumerated().map { index, page in
            let id = "\(unit.id)#\(index)"
            let url = images.appending(path: page.imgPath)
            return ReaderPage(id: id, load: { try await MangaImages.image(at: url, cacheKey: id) },
                              text: page.pageText())
        }
    }
}

extension AidokuRunner.Chapter {
    /// 第3話 · 第1巻 · title, as much as the source gives.
    var displayTitle: String {
        var parts: [String] = []
        if let volumeNumber { parts.append(String(localized: "第\(Self.number(volumeNumber))巻")) }
        if let chapterNumber { parts.append(String(localized: "第\(Self.number(chapterNumber))話")) }
        if let title, !title.isEmpty { parts.append(title) }
        return parts.isEmpty ? key : parts.joined(separator: " ")
    }

    private static func number(_ value: Float) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

// MARK: - Images

/// Page images, decoded off the main actor and kept for the pages around
/// the one being read.
enum MangaImages {
    /// Kept by size, not count: a dozen full scans could pass 500 MB.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 240 * 1024 * 1024
        return cache
    }()

    /// The largest side a page is decoded at: sharper than any screen
    /// shows unzoomed, far smaller than a raw scan.
    nonisolated static let maxPixel: CGFloat = 2600

    private static func store(_ image: UIImage, _ key: String) {
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        cache.setObject(image, forKey: key as NSString, cost: pixels * 4)
    }

    static func cached(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// A file on the phone or an image on the web.
    static func image(at url: URL, cacheKey: String) async throws -> UIImage {
        if let image = cached(cacheKey) { return image }
        let image = try await fetch(url)
        store(image, cacheKey)
        return image
    }

    /// A source's page: its own request (headers, referer) when it makes
    /// one, and its own unscrambling when it does that.
    static func sourcePage(url: URL, context: PageContext?, source: AidokuRunner.Source,
                           cacheKey: String) async throws -> UIImage {
        if let image = cached(cacheKey) { return image }
        var request = URLRequest(url: url)
        if source.features.providesImageRequests,
           let custom = try? await source.getImageRequest(url: url.absoluteString, context: context) {
            request = custom
        }
        request = MangaSources.prepared(request)
        let (data, response) = try await URLSession.shared.data(for: request)
        // A source that unscrambles pages works in the original's pixels,
        // so its pages are decoded whole.
        var image = try await decode(data, maxPixel: source.features.processesPages ? nil : maxPixel)
        if source.features.processesPages {
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
            }
            let reference = try await source.store(value: image)
            let processed = try? await source.processPageImage(
                response: Response(code: http?.statusCode ?? 200,
                                   headers: headers,
                                   request: Request(url: request.url, headers: request.allHTTPHeaderFields ?? [:]),
                                   image: reference),
                context: context)
            try? await source.remove(value: reference)
            if let processed { image = processed }
        }
        store(image, cacheKey)
        return image
    }

    @concurrent
    private nonisolated static func fetch(_ url: URL) async throws -> UIImage {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            var request = URLRequest(url: url)
            request.setValue(SafariUserAgent.mobile, forHTTPHeaderField: "User-Agent")
            data = try await URLSession.shared.data(for: request).0
        }
        return try await decode(data, maxPixel: maxPixel)
    }

    @concurrent
    private nonisolated static func decode(_ data: Data, maxPixel: CGFloat?) async throws -> UIImage {
        if let maxPixel, let image = downsample(data, maxPixel: maxPixel) { return image }
        guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        return image.preparingForDisplay() ?? image
    }

    /// Decodes straight to at most `maxPixel` on the longer side (ImageIO
    /// never holds the full-size bitmap), already prepared for drawing.
    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    @concurrent
    nonisolated static func decodeVolume(at url: URL) async throws -> MokuroVolume {
        try MokuroVolume.decode(Data(contentsOf: url))
    }

    /// A page of a book on the phone, at a size that keeps a long volume's
    /// pages from filling memory.
    static func localPage(_ book: LocalBook, index: Int, cacheKey: String) async throws -> UIImage {
        if let image = cached(cacheKey) { return image }
        let image = try await book.image(at: index, maxPixel: maxPixel)
        store(image, cacheKey)
        return image
    }

    /// The book's mokuro text, page by page: from the .mokuro beside it or
    /// inside it, matched by file name (or by position when the names
    /// differ but the counts agree).
    static func mokuroText(for volume: LocalVolume, book: LocalBook, pageNames: [String]) async -> [PageText?]? {
        var data: Data?
        if let sidecar = volume.sidecar { data = try? Data(contentsOf: sidecar) }
        if data == nil { data = await book.embeddedMokuro() }
        guard let data, let mokuro = try? MokuroVolume.decode(data) else { return nil }
        return matchMokuro(mokuro, pageNames: pageNames)
    }

    nonisolated static func matchMokuro(_ mokuro: MokuroVolume, pageNames: [String]) -> [PageText?] {
        func stem(_ name: String) -> String {
            ((name as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        }
        var byName: [String: MokuroVolume.Page] = [:]
        for page in mokuro.pages { byName[stem(page.imgPath)] = page }
        let matched = pageNames.map { byName[stem($0)]?.pageText() }
        if matched.allSatisfy({ $0 == nil }), mokuro.pages.count == pageNames.count {
            return mokuro.pages.map { $0.pageText() }
        }
        return matched
    }
}
