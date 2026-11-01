//
//  Mokuro.swift
//  Donguri
//
//  Manga already read by mokuro (github.com/kha-white/mokuro): a volume is
//  `<name>.mokuro` (JSON: every page's speech bubbles, their lines and where
//  each line sits) next to a folder `<name>/` of page images. Volumes come
//  from Files (a folder or a zip/cbz holding both) or from a web address
//  that serves them, either a .mokuro file or a plain directory listing.
//  The lines become OCRLines with their characters placed, so the reader
//  taps and highlights them exactly like Vision's text.
//

import Foundation
import UIKit
import ZIPFoundation

nonisolated struct MokuroVolume: Decodable, Sendable {
    let title: String?
    let volume: String?
    let volumeUUID: String?
    let pages: [Page]

    nonisolated struct Page: Decodable, Sendable {
        let imgWidth: Double
        let imgHeight: Double
        let imgPath: String
        let blocks: [Block]

        private enum CodingKeys: String, CodingKey {
            case imgWidth = "img_width", imgHeight = "img_height", imgPath = "img_path", blocks
        }
    }

    nonisolated struct Block: Decodable, Sendable {
        let box: [Double]
        let vertical: Bool
        let lines: [String]
        let linesCoords: [[[Double]]]

        private enum CodingKeys: String, CodingKey {
            case box, vertical, lines, linesCoords = "lines_coords"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            box = try container.decode([Double].self, forKey: .box)
            vertical = try container.decodeIfPresent(Bool.self, forKey: .vertical) ?? true
            lines = try container.decode([String].self, forKey: .lines)
            linesCoords = try container.decodeIfPresent([[[Double]]].self, forKey: .linesCoords) ?? []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case title, volume, volumeUUID = "volume_uuid", pages
    }

    static func decode(_ data: Data) throws -> MokuroVolume {
        try JSONDecoder().decode(MokuroVolume.self, from: data)
    }
}

extension MokuroVolume.Page {
    /// The page's text as tappable lines, normalised to the image.
    nonisolated func textLines() -> [OCRLine] {
        guard imgWidth > 0, imgHeight > 0 else { return [] }
        var result: [OCRLine] = []
        for block in blocks {
            let lines = block.lines.map { $0.trimmingCharacters(in: .whitespaces) }
            let blockText = lines.joined()
            for (index, text) in lines.enumerated() where !text.isEmpty {
                guard let box = lineBox(block: block, index: index) else { continue }
                let characters = Array(text)
                let count = CGFloat(characters.count)
                let boxes: [CGRect] = characters.indices.map { offset in
                    let i = CGFloat(offset)
                    return block.vertical
                        ? CGRect(x: box.minX, y: box.minY + box.height * i / count,
                                 width: box.width, height: box.height / count)
                        : CGRect(x: box.minX + box.width * i / count, y: box.minY,
                                 width: box.width / count, height: box.height)
                }
                result.append(OCRLine(text: text, box: box, isVertical: block.vertical,
                                      characterBoxes: boxes,
                                      blockText: lines.count > 1 ? blockText : nil,
                                      followingText: lines.dropFirst(index + 1).joined()))
            }
        }
        return result
    }

    /// A line's own quadrilateral when mokuro gives one, else its share of
    /// the bubble.
    private nonisolated func lineBox(block: MokuroVolume.Block, index: Int) -> CGRect? {
        if index < block.linesCoords.count {
            let points = block.linesCoords[index].filter { $0.count >= 2 }
            if let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
               let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max(),
               maxX > minX, maxY > minY {
                return CGRect(x: minX / imgWidth, y: minY / imgHeight,
                              width: (maxX - minX) / imgWidth, height: (maxY - minY) / imgHeight)
            }
        }
        guard block.box.count == 4, !block.lines.isEmpty else { return nil }
        let (x1, y1, x2, y2) = (block.box[0], block.box[1], block.box[2], block.box[3])
        let share = 1 / Double(block.lines.count)
        if block.vertical {
            // Columns run right to left.
            let width = (x2 - x1) * share
            let x = x2 - width * Double(index + 1)
            return CGRect(x: x / imgWidth, y: y1 / imgHeight, width: width / imgWidth, height: (y2 - y1) / imgHeight)
        } else {
            let height = (y2 - y1) * share
            let y = y1 + height * Double(index)
            return CGRect(x: x1 / imgWidth, y: y / imgHeight, width: (x2 - x1) / imgWidth, height: height / imgHeight)
        }
    }
}

// MARK: - Volumes on the phone

/// A volume imported from Files, kept under Application Support.
struct LocalMokuroVolume: Identifiable, Hashable, Sendable {
    /// Its folder's name.
    let id: String
    let title: String
    let volume: String
    let mokuroURL: URL

    /// mokuro puts the images in a folder named after the .mokuro file.
    var imagesURL: URL { mokuroURL.deletingPathExtension() }
}

@Observable
final class MokuroLibrary {
    static let shared = MokuroLibrary()

    private static let remoteKey = "iroha.manga.mokuroLibraries"

    private(set) var volumes: [LocalMokuroVolume] = []
    /// Web addresses that serve mokuro volumes.
    private(set) var remotes: [URL]

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Mokuro", directoryHint: .isDirectory)
    }

    private init() {
        remotes = (UserDefaults.standard.stringArray(forKey: Self.remoteKey) ?? []).compactMap(URL.init(string:))
        reload()
    }

    var titles: [(title: String, volumes: [LocalMokuroVolume])] {
        Dictionary(grouping: volumes, by: \.title)
            .map { (title: $0.key, volumes: $0.value.sorted { $0.volume.localizedStandardCompare($1.volume) == .orderedAscending }) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        volumes = folders.compactMap { folder in
            guard let mokuro = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension.lowercased() == "mokuro" }) else { return nil }
            let header = Self.header(of: mokuro)
            return LocalMokuroVolume(id: folder.lastPathComponent,
                                     title: header.title ?? mokuro.deletingPathExtension().lastPathComponent,
                                     volume: header.volume ?? mokuro.deletingPathExtension().lastPathComponent,
                                     mokuroURL: mokuro)
        }
    }

    func delete(_ volume: LocalMokuroVolume) {
        try? FileManager.default.removeItem(at: Self.directory.appending(path: volume.id, directoryHint: .isDirectory))
        reload()
    }

    /// Imports every volume in a folder or zip/cbz picked in Files.
    /// Returns how many were found.
    func importItem(at url: URL) async throws -> Int {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let count = try await Self.importVolumes(from: url, into: Self.directory)
        reload()
        return count
    }

    @concurrent
    private nonisolated static func importVolumes(from url: URL, into directory: URL) async throws -> Int {
        let manager = FileManager.default
        var root = url
        var temporary: URL?
        defer { if let temporary { try? manager.removeItem(at: temporary) } }
        if !url.hasDirectoryPath, ["zip", "cbz"].contains(url.pathExtension.lowercased()) {
            let folder = manager.temporaryDirectory.appending(path: "mokuro-\(UUID().uuidString)")
            try manager.unzipItem(at: url, to: folder)
            temporary = folder
            root = folder
        }
        let mokuroFiles = root.pathExtension.lowercased() == "mokuro" ? [root] : findMokuroFiles(in: root)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var imported = 0
        for file in mokuroFiles {
            let images = file.deletingPathExtension()
            guard manager.fileExists(atPath: images.path) else { continue }
            let destination = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            try manager.copyItem(at: file, to: destination.appending(path: file.lastPathComponent))
            try manager.copyItem(at: images, to: destination.appending(path: images.lastPathComponent, directoryHint: .isDirectory))
            imported += 1
        }
        return imported
    }

    private nonisolated static func findMokuroFiles(in folder: URL) -> [URL] {
        var files: [URL] = []
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        for case let file as URL in walker where file.pathExtension.lowercased() == "mokuro" {
            files.append(file)
        }
        return files
    }

    /// Title and volume without decoding every page.
    private static func header(of url: URL) -> (title: String?, volume: String?) {
        struct Header: Decodable { let title: String?; let volume: String? }
        guard let data = try? Data(contentsOf: url),
              let header = try? JSONDecoder().decode(Header.self, from: data) else { return (nil, nil) }
        return (header.title, header.volume)
    }

    // MARK: Remote libraries

    func addRemote(_ string: String) -> URL? {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), url.host() != nil else { return nil }
        if !remotes.contains(url) {
            remotes.append(url)
            UserDefaults.standard.set(remotes.map(\.absoluteString), forKey: Self.remoteKey)
        }
        return url
    }

    func removeRemote(_ url: URL) {
        remotes.removeAll { $0 == url }
        UserDefaults.standard.set(remotes.map(\.absoluteString), forKey: Self.remoteKey)
    }
}

// MARK: - Browsing a web address

/// What's at a web address that serves mokuro volumes.
nonisolated enum MokuroRemoteEntry: Hashable, Identifiable, Sendable {
    case folder(name: String, url: URL)
    case volume(name: String, url: URL)

    var id: URL {
        switch self {
        case .folder(_, let url), .volume(_, let url): url
        }
    }

    var name: String {
        switch self {
        case .folder(let name, _), .volume(let name, _): name
        }
    }
}

nonisolated enum MokuroRemote {
    /// The folders and volumes a directory listing links to. A volume's
    /// image folder is left out: it's part of the volume.
    @concurrent
    static func list(_ url: URL) async throws -> [MokuroRemoteEntry] {
        var request = URLRequest(url: url)
        request.setValue(SafariUserAgent.mobile, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        let base = url.hasDirectoryPath ? url : URL(string: url.absoluteString + "/") ?? url
        let pattern = /href\s*=\s*["']([^"'#?]+)["']/
        var folders: [String: URL] = [:]
        var volumes: [String: URL] = [:]
        for match in html.matches(of: pattern) {
            let href = String(match.output.1)
            guard !href.hasPrefix("../"), href != "./", href != "/",
                  let target = URL(string: href, relativeTo: base)?.absoluteURL,
                  target.absoluteString.hasPrefix(base.absoluteString),
                  target.absoluteString != base.absoluteString else { continue }
            let name = target.deletingPathExtension().lastPathComponent
            if target.pathExtension.lowercased() == "mokuro" {
                volumes[name] = target
            } else if href.hasSuffix("/") {
                folders[target.lastPathComponent] = target
            }
        }
        for name in volumes.keys { folders[name] = nil }
        let sortedFolders = folders.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { MokuroRemoteEntry.folder(name: $0.key, url: $0.value) }
        let sortedVolumes = volumes.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { MokuroRemoteEntry.volume(name: $0.key, url: $0.value) }
        return sortedFolders + sortedVolumes
    }

    @concurrent
    static func volume(at url: URL) async throws -> MokuroVolume {
        var request = URLRequest(url: url)
        request.setValue(SafariUserAgent.mobile, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try MokuroVolume.decode(data)
    }
}
