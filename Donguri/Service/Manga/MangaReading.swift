//
//  MangaReading.swift
//  Donguri
//
//  What the manga reader is handed: a run of reading units (a source's
//  chapters, or a title's mokuro volumes) and how to load each unit's
//  pages. A page loads its own image and may bring its text (mokuro);
//  pages without text can be read by Vision in the reader.
//

import Foundation
import UIKit
import AidokuRunner

/// One chapter or volume.
struct ReaderUnit: Identifiable, Hashable {
    /// Where its reading position is kept (MangaLibrary).
    let id: String
    let label: String
}

struct ReaderPage: Identifiable {
    let id: String
    let load: () async throws -> UIImage
    /// mokuro's text, already placed on the page.
    var text: [OCRLine]?
}

struct ReaderRequest: Identifiable {
    let id = UUID()
    /// The manga's title, which becomes the card's document title.
    let title: String
    /// In reading order (first chapter first).
    let units: [ReaderUnit]
    let startIndex: Int
    let rightToLeft: Bool
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
        let rightToLeft = manga.viewer != .leftToRight && manga.viewer != .vertical && manga.viewer != .webtoon
        return ReaderRequest(title: manga.title,
                             units: units,
                             startIndex: units.firstIndex { $0.id == startID } ?? 0,
                             rightToLeft: rightToLeft,
                             mangaID: MangaLibrary.mangaID(source: source.key, manga: manga.key)) { unit in
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

    /// The volumes of one title on the phone.
    static func local(title: String, volumes: [LocalMokuroVolume], start: LocalMokuroVolume) -> ReaderRequest {
        let units = volumes.map { ReaderUnit(id: "mokuro\u{1F}\($0.id)", label: $0.volume) }
        let byID = Dictionary(uniqueKeysWithValues: zip(units.map(\.id), volumes))
        return ReaderRequest(title: title,
                             units: units,
                             startIndex: volumes.firstIndex(of: start) ?? 0,
                             rightToLeft: true) { unit in
            guard let volume = byID[unit.id] else { throw MangaReaderError.noPages }
            let mokuro = try await MangaImages.decodeVolume(at: volume.mokuroURL)
            return mokuroPages(mokuro, unit: unit, images: volume.imagesURL)
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
                             rightToLeft: true) { unit in
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
                              text: page.textLines())
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
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 14
        return cache
    }()

    static func cached(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// A file on the phone or an image on the web.
    static func image(at url: URL, cacheKey: String) async throws -> UIImage {
        if let image = cached(cacheKey) { return image }
        let image = try await fetch(url)
        cache.setObject(image, forKey: cacheKey as NSString)
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
        var image = try await decode(data)
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
        cache.setObject(image, forKey: cacheKey as NSString)
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
        return try await decode(data)
    }

    @concurrent
    private nonisolated static func decode(_ data: Data) async throws -> UIImage {
        guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        return image.preparingForDisplay() ?? image
    }

    @concurrent
    nonisolated static func decodeVolume(at url: URL) async throws -> MokuroVolume {
        try MokuroVolume.decode(Data(contentsOf: url))
    }
}
