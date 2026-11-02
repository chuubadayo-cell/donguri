//
//  LocalManga.swift
//  Donguri
//
//  Manga files on the phone, read where they are, Suwayomi's local-source
//  way: the いろは › Manga folder in the Files app holds them. A folder in
//  it is a series and each book inside is a volume; a book at the top is a
//  series of one. Books are CBZ/ZIP archives, PDFs, EPUBs made of page
//  images, folders of images, or single images. A `.mokuro` file beside a
//  book (same name), or inside it, gives its pages' text, as in Manatan.
//  Importing from the app copies into the same folder.
//

import Foundation
import UIKit
import PDFKit
import ZIPFoundation

nonisolated enum LocalBookKind: String, Sendable {
    case archive, pdf, epub, folder, image

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "bmp", "tif", "tiff"]

    init?(file url: URL) {
        switch url.pathExtension.lowercased() {
        case "zip", "cbz": self = .archive
        case "pdf": self = .pdf
        case "epub": self = .epub
        case let ext where Self.imageExtensions.contains(ext): self = .image
        default: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .archive: "doc.zipper"
        case .pdf: "doc.richtext"
        case .epub: "book"
        case .folder: "folder"
        case .image: "photo"
        }
    }
}

nonisolated struct LocalVolume: Identifiable, Hashable, Sendable {
    /// Its path under the Manga folder.
    let id: String
    let title: String
    let url: URL
    let kind: LocalBookKind
    /// A `.mokuro` beside it.
    let sidecar: URL?

    var unitID: String { "local\u{1F}\(id)" }
}

nonisolated struct LocalSeries: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let volumes: [LocalVolume]
}

@Observable
final class LocalMangaLibrary {
    static let shared = LocalMangaLibrary()

    private(set) var series: [LocalSeries] = []
    private(set) var isScanning = false
    private var scanned = false

    nonisolated static var root: URL {
        URL.documentsDirectory.appending(path: "Manga", directoryHint: .isDirectory)
    }

    private init() {}

    func series(id: String) -> LocalSeries? {
        series.first { $0.id == id }
    }

    func scanIfNeeded() async {
        guard !scanned else { return }
        await scan()
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        scanned = true
        await Self.migrateMokuroImports()
        let found = await Self.scan(root: Self.root)
        // Unchanged, the list is left alone: replacing it mid-tap ate taps.
        if found != series { series = found }
    }

    /// Copies books (and folders of them) picked in Files into the Manga
    /// folder. Returns how many items were copied.
    func importItems(_ urls: [URL]) async throws -> Int {
        var count = 0
        for url in urls {
            // Already in the Manga folder (opened from it in Files).
            if url.standardizedFileURL.path.hasPrefix(Self.root.standardizedFileURL.path) { continue }
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            try await Self.copy(url, into: Self.root)
            count += 1
        }
        await scan()
        return count
    }

    func delete(_ volume: LocalVolume) async {
        let manager = FileManager.default
        try? manager.removeItem(at: volume.url)
        if let sidecar = volume.sidecar { try? manager.removeItem(at: sidecar) }
        let parent = volume.url.deletingLastPathComponent()
        if parent.standardizedFileURL != Self.root.standardizedFileURL,
           (try? manager.contentsOfDirectory(atPath: parent.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
            try? manager.removeItem(at: parent)
        }
        await scan()
    }

    func delete(_ series: LocalSeries) async {
        for volume in series.volumes {
            try? FileManager.default.removeItem(at: volume.url)
            if let sidecar = volume.sidecar { try? FileManager.default.removeItem(at: sidecar) }
        }
        let folder = Self.root.appending(path: series.id, directoryHint: .isDirectory)
        if series.volumes.count > 0, folder.standardizedFileURL != Self.root.standardizedFileURL,
           FileManager.default.fileExists(atPath: folder.path),
           series.volumes.allSatisfy({ $0.url.path.hasPrefix(folder.path) }) {
            try? FileManager.default.removeItem(at: folder)
        }
        await scan()
    }

    // MARK: Scanning

    @concurrent
    private nonisolated static func scan(root: URL) async -> [LocalSeries] {
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        var result: [LocalSeries] = []
        for item in children(of: root) {
            if item.hasDirectoryPath {
                let volumes = volumes(in: item, root: root)
                if !volumes.isEmpty {
                    result.append(LocalSeries(id: relative(item, to: root), title: item.lastPathComponent, volumes: volumes))
                }
            } else if let kind = LocalBookKind(file: item) {
                let volume = LocalVolume(id: relative(item, to: root), title: item.deletingPathExtension().lastPathComponent,
                                         url: item, kind: kind, sidecar: sidecar(for: item))
                result.append(LocalSeries(id: volume.id, title: volume.title, volumes: [volume]))
            }
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Books anywhere in a series folder, and folders holding images.
    private nonisolated static func volumes(in folder: URL, root: URL) -> [LocalVolume] {
        var result: [LocalVolume] = []
        let items = children(of: folder)
        let images = items.filter { !$0.hasDirectoryPath && LocalBookKind.imageExtensions.contains($0.pathExtension.lowercased()) }
        if !images.isEmpty {
            result.append(LocalVolume(id: relative(folder, to: root), title: folder.lastPathComponent,
                                      url: folder, kind: .folder, sidecar: sidecar(for: folder)))
        }
        for item in items {
            if item.hasDirectoryPath {
                result += volumes(in: item, root: root)
            } else if let kind = LocalBookKind(file: item), kind != .image {
                result.append(LocalVolume(id: relative(item, to: root), title: item.deletingPathExtension().lastPathComponent,
                                          url: item, kind: kind, sidecar: sidecar(for: item)))
            }
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    nonisolated static func children(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDirectory ? url.appending(path: "", directoryHint: .isDirectory) : url
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private nonisolated static func sidecar(for url: URL) -> URL? {
        let base = url.hasDirectoryPath ? URL(fileURLWithPath: url.path) : url.deletingPathExtension()
        let exact = URL(fileURLWithPath: base.path + ".mokuro")
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        if url.hasDirectoryPath {
            return children(of: url).first { $0.pathExtension.lowercased() == "mokuro" }
        }
        return nil
    }

    private nonisolated static func relative(_ url: URL, to root: URL) -> String {
        let path = URL(fileURLWithPath: url.path).standardizedFileURL.path
        let base = root.standardizedFileURL.path
        var result = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
        while result.hasPrefix("/") { result.removeFirst() }
        return result
    }

    @concurrent
    private nonisolated static func copy(_ url: URL, into root: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var destination = root.appending(path: url.lastPathComponent)
        var counter = 2
        while manager.fileExists(atPath: destination.path) {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            destination = root.appending(path: ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)")
            counter += 1
        }
        try manager.copyItem(at: url, to: destination)
        // A .mokuro beside the picked file comes with it when it can be read.
        if !url.hasDirectoryPath {
            let sidecar = url.deletingPathExtension().appendingPathExtension("mokuro")
            if manager.fileExists(atPath: sidecar.path) {
                try? manager.copyItem(at: sidecar, to: destination.deletingPathExtension().appendingPathExtension("mokuro"))
            }
        }
    }

    /// mokuro volumes imported before the Manga folder existed lived in
    /// Application Support/Mokuro/<id>/; they move into Manga/<title>/.
    @concurrent
    private nonisolated static func migrateMokuroImports() async {
        let manager = FileManager.default
        let old = URL.applicationSupportDirectory.appending(path: "Mokuro", directoryHint: .isDirectory)
        guard let folders = try? manager.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            guard let mokuro = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension.lowercased() == "mokuro" }) else { continue }
            struct Header: Decodable { let title: String? }
            let title = (try? JSONDecoder().decode(Header.self, from: Data(contentsOf: mokuro)))?.title
                ?? mokuro.deletingPathExtension().lastPathComponent
            let safeTitle = title.replacingOccurrences(of: "/", with: "／")
            let series = root.appending(path: safeTitle, directoryHint: .isDirectory)
            try? manager.createDirectory(at: series, withIntermediateDirectories: true)
            for item in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                let target = series.appending(path: item.lastPathComponent)
                if !manager.fileExists(atPath: target.path) {
                    try? manager.moveItem(at: item, to: target)
                }
            }
        }
        try? manager.removeItem(at: old)
    }
}

// MARK: - Reading a book

/// Opens a book and hands out its pages. One per volume being read; an
/// actor because archives and PDFs aren't safe to read from two threads.
actor LocalBook {
    private let volume: LocalVolume
    private var archive: Archive?
    private var pdf: PDFDocument?
    /// Archive entry paths, or file URLs' paths, in page order.
    private var pagePaths: [String] = []
    private var opened = false

    init(volume: LocalVolume) {
        self.volume = volume
    }

    enum Failure: LocalizedError {
        case unreadable, noImages, textBook

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "ファイルを開けませんでした")
            case .noImages: String(localized: "ページの画像が見つかりませんでした")
            case .textBook: String(localized: "文章のEPUBにはまだ対応していません")
            }
        }
    }

    /// The pages' file names, for matching mokuro's.
    func open() throws -> [String] {
        if !opened {
            opened = true
            switch volume.kind {
            case .archive:
                let archive = try Archive(url: volume.url, accessMode: .read)
                self.archive = archive
                pagePaths = archive.map(\.path)
                    .filter { Self.isPageImage($0) }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            case .epub:
                let archive = try Archive(url: volume.url, accessMode: .read)
                self.archive = archive
                pagePaths = try EPUBPages.images(in: archive)
            case .pdf:
                guard let document = PDFDocument(url: volume.url) else { throw Failure.unreadable }
                pdf = document
                pagePaths = (0..<document.pageCount).map { String(format: "%04d.pdf-page", $0 + 1) }
            case .folder:
                pagePaths = LocalMangaLibrary.children(of: volume.url)
                    .filter { !$0.hasDirectoryPath && LocalBookKind.imageExtensions.contains($0.pathExtension.lowercased()) }
                    .map(\.path)
            case .image:
                pagePaths = [volume.url.path]
            }
        }
        if pagePaths.isEmpty { throw Failure.noImages }
        return pagePaths.map { ($0 as NSString).lastPathComponent }
    }

    /// mokuro's text inside the book (an archive or folder that carries
    /// its own .mokuro), when there's no file beside it.
    func embeddedMokuro() -> Data? {
        if let archive, let entry = archive.first(where: { $0.path.lowercased().hasSuffix(".mokuro") }) {
            return Self.data(of: entry, in: archive)
        }
        return nil
    }

    func image(at index: Int, maxPixel: CGFloat) throws -> UIImage {
        _ = try open()
        guard pagePaths.indices.contains(index) else { throw Failure.noImages }
        let data: Data
        switch volume.kind {
        case .archive, .epub:
            guard let archive, let entry = archive[pagePaths[index]], let extracted = Self.data(of: entry, in: archive) else {
                throw Failure.unreadable
            }
            data = extracted
        case .pdf:
            guard let page = pdf?.page(at: index) else { throw Failure.unreadable }
            let bounds = page.bounds(for: .mediaBox)
            let scale = maxPixel / max(bounds.width, bounds.height, 1)
            let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            return image
        case .folder, .image:
            data = try Data(contentsOf: URL(fileURLWithPath: pagePaths[index]))
        }
        if let image = MangaImages.downsample(data, maxPixel: maxPixel) { return image }
        guard let image = UIImage(data: data) else { throw Failure.unreadable }
        return image.preparingForDisplay() ?? image
    }

    private static func data(of entry: Entry, in archive: Archive) -> Data? {
        var data = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        } catch {
            return nil
        }
        return data
    }

    private static func isPageImage(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let name = components.last, !name.hasPrefix("."), !components.contains("__MACOSX") else { return false }
        return LocalBookKind.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}

/// The page images of an image EPUB (most manga EPUBs): each spine page's
/// image, in spine order.
nonisolated enum EPUBPages {
    static func images(in archive: Archive) throws -> [String] {
        guard let container = text(of: "META-INF/container.xml", in: archive),
              let opfPath = first(#"full-path\s*=\s*"([^"]+)""#, in: container),
              let opf = text(of: opfPath, in: archive) else { throw LocalBook.Failure.unreadable }
        let opfFolder = (opfPath as NSString).deletingLastPathComponent

        var manifest: [String: (href: String, type: String)] = [:]
        var manifestOrder: [String] = []
        for item in all(#"<item\b[^>]*>"#, in: opf) {
            guard let id = first(#"\bid\s*=\s*"([^"]+)""#, in: item),
                  let href = first(#"\bhref\s*=\s*"([^"]+)""#, in: item) else { continue }
            manifest[id] = (resolve(href, from: opfFolder), first(#"media-type\s*=\s*"([^"]+)""#, in: item) ?? "")
            manifestOrder.append(id)
        }
        let spine = all(#"<itemref\b[^>]*>"#, in: opf).compactMap { first(#"idref\s*=\s*"([^"]+)""#, in: $0) }

        var pages: [String] = []
        var seen: Set<String> = []
        for id in spine {
            guard let item = manifest[id] else { continue }
            if item.type.hasPrefix("image/") {
                if seen.insert(item.href).inserted { pages.append(item.href) }
                continue
            }
            guard let page = text(of: item.href, in: archive) else { continue }
            let folder = (item.href as NSString).deletingLastPathComponent
            let refs = all(#"<img\b[^>]*\bsrc\s*=\s*"([^"]+)""#, in: page, group: 1)
                + all(#"<image\b[^>]*\bhref\s*=\s*"([^"]+)""#, in: page, group: 1)
            for ref in refs {
                let path = resolve(ref, from: folder)
                if archive[path] != nil, seen.insert(path).inserted { pages.append(path) }
            }
        }
        if pages.isEmpty {
            pages = manifestOrder.compactMap { manifest[$0] }.filter { $0.type.hasPrefix("image/") }.map(\.href)
            if pages.count < 2 { throw LocalBook.Failure.textBook }
        }
        return pages
    }

    private static func text(of path: String, in archive: Archive) -> String? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        guard (try? archive.extract(entry, skipCRC32: true, consumer: { data.append($0) })) != nil else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func resolve(_ href: String, from folder: String) -> String {
        let decoded = (href.split(separator: "#").first.map(String.init) ?? href).removingPercentEncoding ?? href
        var parts = folder.isEmpty ? [] : folder.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/").map(String.init) {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else if part != "." { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        all(pattern, in: text, group: 1).first
    }

    private static func all(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard group < match.numberOfRanges, let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }
}
