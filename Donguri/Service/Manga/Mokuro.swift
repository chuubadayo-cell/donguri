//
//  Mokuro.swift
//  Donguri
//
//  Manga already read by mokuro (github.com/kha-white/mokuro): a volume is
//  `<name>.mokuro` (JSON: every page's speech bubbles, their lines and where
//  each line sits) next to a folder `<name>/` of page images, or beside an
//  archive of them. On the phone they're books in the Manga folder
//  (LocalMangaLibrary); here are the format and web addresses that serve
//  volumes, either a .mokuro file or a plain directory listing. The text
//  becomes a PageText, as OCR's does.
//

import Foundation
import UIKit

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
    /// The page's speech bubbles, normalised to the image.
    nonisolated func pageText() -> PageText {
        guard imgWidth > 0, imgHeight > 0 else { return .empty }
        var result: [PageText.Block] = []
        for block in blocks {
            var lines: [PageText.Line] = []
            for (index, raw) in block.lines.enumerated() {
                let text = raw.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, let box = lineBox(block: block, index: index) else { continue }
                lines.append(PageText.Line(text: text, box: box, characters: nil))
            }
            guard let first = lines.first else { continue }
            var box = lines.dropFirst().reduce(first.box) { $0.union($1.box) }
            if block.box.count == 4 {
                box = CGRect(x: block.box[0] / imgWidth, y: block.box[1] / imgHeight,
                             width: (block.box[2] - block.box[0]) / imgWidth,
                             height: (block.box[3] - block.box[1]) / imgHeight).union(box)
            }
            result.append(PageText.Block(box: box, vertical: block.vertical, lines: lines))
        }
        return PageText(blocks: result)
    }

    /// The page's text as tappable lines.
    nonisolated func textLines() -> [OCRLine] {
        pageText().ocrLines()
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

// MARK: - Web libraries

/// Web addresses that serve mokuro volumes. (Volumes on the phone live in
/// the Manga folder: LocalMangaLibrary.)
@Observable
final class MokuroLibrary {
    static let shared = MokuroLibrary()

    private static let remoteKey = "iroha.manga.mokuroLibraries"

    private(set) var remotes: [URL]

    private init() {
        remotes = (UserDefaults.standard.stringArray(forKey: Self.remoteKey) ?? []).compactMap(URL.init(string:))
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
