//
//  MangaOCR.swift
//  Donguri
//
//  A manga page's text, Manatan-style: found automatically, grouped into
//  speech bubbles, and kept on disk so a page is read only once. The text
//  comes from mokuro when a volume has it, else from Apple's Vision on
//  the phone, or from Google Cloud Vision with the user's own API key
//  (what Manatan uses; much better at vertical text, but the page is sent
//  to Google). Every source ends up as a PageText, which becomes the
//  tappable OCRLines.
//

import Foundation
import UIKit
import CryptoKit
import Vision

/// A page's speech bubbles, normalised to the image (0…1, top left).
nonisolated struct PageText: Codable, Sendable, Equatable {
    var blocks: [Block]

    nonisolated struct Block: Codable, Sendable, Equatable {
        var box: CGRect
        var vertical: Bool
        var lines: [Line]

        var text: String { lines.map(\.text).joined() }
    }

    nonisolated struct Line: Codable, Sendable, Equatable {
        var text: String
        var box: CGRect
        /// One per character when the engine placed them; else they're
        /// spread evenly along the line.
        var characters: [CGRect]?
    }

    static let empty = PageText(blocks: [])

    var isEmpty: Bool { blocks.isEmpty }

    /// The lines as the image view taps and draws them.
    func ocrLines() -> [OCRLine] {
        var result: [OCRLine] = []
        for block in blocks {
            let texts = block.lines.map(\.text)
            let blockText = block.lines.count > 1 ? block.text : nil
            for (index, line) in block.lines.enumerated() where !line.text.isEmpty {
                let count = line.text.count
                let boxes: [CGRect]
                if let characters = line.characters, characters.count == count {
                    boxes = characters
                } else {
                    let total = CGFloat(count)
                    boxes = (0..<count).map { offset in
                        let i = CGFloat(offset)
                        return block.vertical
                            ? CGRect(x: line.box.minX, y: line.box.minY + line.box.height * i / total,
                                     width: line.box.width, height: line.box.height / total)
                            : CGRect(x: line.box.minX + line.box.width * i / total, y: line.box.minY,
                                     width: line.box.width / total, height: line.box.height)
                    }
                }
                result.append(OCRLine(text: line.text, box: line.box, isVertical: block.vertical,
                                      characterBoxes: boxes, blockText: blockText,
                                      followingText: texts.dropFirst(index + 1).joined()))
            }
        }
        return result
    }

    /// The bubble under a normalised point, with a little slack.
    func blockIndex(at point: CGPoint) -> Int? {
        let slack: CGFloat = 0.01
        return blocks.indices
            .filter { blocks[$0].box.insetBy(dx: -slack, dy: -slack).contains(point) }
            .min { blocks[$0].box.width * blocks[$0].box.height < blocks[$1].box.width * blocks[$1].box.height }
    }
}

// MARK: - Engines

enum MangaOCREngine: String, CaseIterable, Identifiable {
    case vision, google
    var id: String { rawValue }
}

enum MangaOCR {
    private static var running: [String: Task<PageText, Never>] = [:]
    private static var memory: [String: PageText] = [:]

    private static var directory: URL {
        URL.cachesDirectory.appending(path: "MangaOCR", directoryHint: .isDirectory)
    }

    /// Already read, without reading it.
    static func cached(key: String) -> PageText? {
        let engine = MangaReaderSettings.shared.ocrEngine
        let id = cacheID(key: key, engine: engine)
        if let text = memory[id] { return text }
        guard let data = try? Data(contentsOf: directory.appending(path: id)),
              let text = try? JSONDecoder().decode(PageText.self, from: data) else { return nil }
        remember(text, id: id)
        return text
    }

    /// The page's text: from the cache, or read now (once, however many
    /// pages ask at the same time).
    static func text(for image: UIImage, key: String, priority: TaskPriority = .userInitiated) async -> PageText {
        if let cached = cached(key: key) { return cached }
        let settings = MangaReaderSettings.shared
        let engine = settings.ocrEngine
        let id = cacheID(key: key, engine: engine)
        if let task = running[id] { return await task.value }
        let apiKey = settings.googleAPIKey
        let task = Task<PageText, Never>(priority: priority) {
            if engine == .google, !apiKey.isEmpty, let text = try? await GoogleVision.read(image, apiKey: apiKey) {
                return text
            }
            return await VisionBubbles.read(image)
        }
        running[id] = task
        let text = await task.value
        running[id] = nil
        remember(text, id: id)
        write(text, id: id)
        return text
    }

    /// Reads it again, ignoring the cache (after switching engines, say).
    static func forget(key: String) {
        let id = cacheID(key: key, engine: MangaReaderSettings.shared.ocrEngine)
        memory[id] = nil
        try? FileManager.default.removeItem(at: directory.appending(path: id))
    }

    static func clearCache() {
        memory = [:]
        try? FileManager.default.removeItem(at: directory)
    }

    private static func remember(_ text: PageText, id: String) {
        memory[id] = text
        if memory.count > 120 { memory.removeAll(keepingCapacity: true) }
    }

    private static func write(_ text: PageText, id: String) {
        let url = directory.appending(path: id)
        let folder = directory
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(text) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func cacheID(key: String, engine: MangaOCREngine) -> String {
        let digest = SHA256.hash(data: Data("\(engine.rawValue)|\(key)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }
}

// MARK: - Vision, grouped into bubbles

nonisolated enum VisionBubbles {
    /// iOS 26's text recognition reads vertical columns; the older API
    /// mostly misses them. Either way some vertical text comes back a
    /// character at a time, so stacked pieces are joined into columns
    /// before the lines are grouped into bubbles.
    static func read(_ image: UIImage) async -> PageText {
        var lines: [OCRLine]
        if #available(iOS 26.0, *), let recognized = await recognizeModern(image) {
            lines = recognized
        } else {
            lines = await TextRecognizer.recognize(image, priority: .userInitiated)
        }
        lines = joinColumns(lines, size: image.size)
        return await group(lines)
    }

    @available(iOS 26.0, *)
    @concurrent
    private static func recognizeModern(_ image: UIImage) async -> [OCRLine]? {
        guard let cgImage = image.cgImage else { return nil }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true
        request.minimumTextHeightFraction = 0.008
        guard let observations = try? await request.perform(on: cgImage,
                                                            orientation: CGImagePropertyOrientation(image.imageOrientation)) else {
            return nil
        }
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        }
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let box = flipped(observation.boundingBox.cgRect)
            let vertical = text.count > 1 && box.height * height > box.width * width * 1.5
            var characters: [CGRect] = []
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(after: index)
                characters.append(candidate.boundingBox(for: index..<next).map { flipped($0.boundingBox.cgRect) } ?? .zero)
                index = next
            }
            // Vision's boxes for characters in a column are unreliable;
            // spread them along the line instead when they look wrong.
            let usable = characters.allSatisfy { !$0.isEmpty && box.insetBy(dx: -0.01, dy: -0.01).contains(CGPoint(x: $0.midX, y: $0.midY)) }
            let count = CGFloat(text.count)
            let boxes = usable && !vertical ? characters : (0..<text.count).map { offset in
                let i = CGFloat(offset)
                return vertical
                    ? CGRect(x: box.minX, y: box.minY + box.height * i / count, width: box.width, height: box.height / count)
                    : CGRect(x: box.minX + box.width * i / count, y: box.minY, width: box.width / count, height: box.height)
            }
            return OCRLine(text: text, box: box, isVertical: vertical, characterBoxes: boxes,
                           blockText: nil, followingText: "")
        }
    }

    /// Joins pieces of one column: vertical lines and short, squarish
    /// pieces stacked one under another, about as wide and close together.
    static func joinColumns(_ lines: [OCRLine], size: CGSize) -> [OCRLine] {
        func isPiece(_ line: OCRLine) -> Bool {
            if line.isVertical { return true }
            guard line.text.count <= 2 else { return false }
            let w = line.box.width * size.width, h = line.box.height * size.height
            return w < h * 2.2
        }
        var pieces = lines.filter(isPiece).sorted { $0.box.minY < $1.box.minY }
        var others = lines.filter { !isPiece($0) }
        var columns: [[OCRLine]] = []
        while !pieces.isEmpty {
            var column = [pieces.removeFirst()]
            var extended = true
            while extended {
                extended = false
                let last = column[column.count - 1]
                let charHeight = last.isVertical ? last.box.height / CGFloat(max(last.text.count, 1)) : last.box.height
                if let next = pieces.firstIndex(where: { piece in
                    let overlap = min(piece.box.maxX, last.box.maxX) - max(piece.box.minX, last.box.minX)
                    let narrower = min(piece.box.width, last.box.width)
                    let gap = piece.box.minY - last.box.maxY
                    return overlap > narrower * 0.6 && gap > -charHeight * 0.5 && gap < charHeight * 0.9
                }) {
                    column.append(pieces.remove(at: next))
                    extended = true
                }
            }
            columns.append(column)
        }
        for column in columns {
            if column.count == 1 {
                others.append(column[0])
                continue
            }
            let text = column.map(\.text).joined()
            let box = column.dropFirst().reduce(column[0].box) { $0.union($1.box) }
            others.append(OCRLine(text: text, box: box, isVertical: true,
                                  characterBoxes: column.flatMap(\.characterBoxes),
                                  blockText: nil, followingText: ""))
        }
        return others
    }

    /// Lines close together, running the same way and about the same size,
    /// are one bubble. Character boxes are worked out here, off the main
    /// actor, since the result is kept.
    @concurrent
    static func group(_ lines: [OCRLine]) async -> PageText {
        let lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return .empty }
        var parent = Array(lines.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func size(_ line: OCRLine) -> CGFloat {
            line.isVertical ? line.box.width : line.box.height
        }
        func reach(_ line: OCRLine) -> CGRect {
            let s = size(line)
            return line.isVertical
                ? line.box.insetBy(dx: -s * 0.9, dy: -s * 0.6)
                : line.box.insetBy(dx: -s * 0.6, dy: -s * 0.9)
        }
        for i in lines.indices {
            for j in lines.indices where j > i {
                let a = lines[i], b = lines[j]
                // A single character runs neither way.
                guard a.isVertical == b.isVertical || a.text.count == 1 || b.text.count == 1 else { continue }
                let ratio = size(a) / max(size(b), 0.0001)
                guard ratio > 0.55, ratio < 1.8 else { continue }
                if reach(a).intersects(b.box) || reach(b).intersects(a.box) {
                    parent[find(i)] = find(j)
                }
            }
        }
        var groups: [Int: [OCRLine]] = [:]
        for i in lines.indices { groups[find(i), default: []].append(lines[i]) }
        let blocks: [PageText.Block] = groups.values.map { members in
            let directed = members.filter { $0.text.count > 1 }
            let vertical = directed.isEmpty
                ? members.contains { $0.box.height >= $0.box.width }
                : directed.filter(\.isVertical).count * 2 >= directed.count
            // Columns right to left; rows top to bottom.
            let ordered = vertical
                ? members.sorted { $0.box.midX > $1.box.midX }
                : members.sorted { $0.box.minY < $1.box.minY }
            let box = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            return PageText.Block(box: box, vertical: vertical,
                                  lines: ordered.map { PageText.Line(text: $0.text, box: $0.box, characters: $0.characterBoxes) })
        }
        // Reading order for the page: top to bottom in bands, right to left.
        return PageText(blocks: blocks.sorted {
            abs($0.box.minY - $1.box.minY) < 0.08 ? $0.box.maxX > $1.box.maxX : $0.box.minY < $1.box.minY
        })
    }
}

// MARK: - Google Cloud Vision

nonisolated enum GoogleVision {
    enum Failure: LocalizedError {
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let message): message
            }
        }
    }

    /// DOCUMENT_TEXT_DETECTION: blocks (bubbles) of words of symbols, each
    /// with its box, and breaks marking the ends of lines.
    @concurrent
    static func read(_ image: UIImage, apiKey: String) async throws -> PageText {
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return .empty }

        var components = URLComponents(string: "https://vision.googleapis.com/v1/images:annotate")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "requests": [[
                "image": ["content": jpeg.base64EncodedString()],
                "features": [["type": "DOCUMENT_TEXT_DETECTION"]],
                "imageContext": ["languageHints": ["ja"]]
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse("Google Cloud Vision")
        }
        if let error = root["error"] as? [String: Any] {
            throw Failure.badResponse(error["message"] as? String ?? "Google Cloud Vision")
        }
        guard let response = (root["responses"] as? [[String: Any]])?.first else { return .empty }
        if let error = response["error"] as? [String: Any] {
            throw Failure.badResponse(error["message"] as? String ?? "Google Cloud Vision")
        }
        guard let annotation = response["fullTextAnnotation"] as? [String: Any],
              let page = (annotation["pages"] as? [[String: Any]])?.first else { return .empty }
        let width = Double(size.width), height = Double(size.height)

        func rect(_ object: [String: Any]?) -> CGRect? {
            guard let vertices = (object?["boundingBox"] as? [String: Any])?["vertices"] as? [[String: Any]],
                  !vertices.isEmpty else { return nil }
            let xs = vertices.map { ($0["x"] as? Double) ?? Double(($0["x"] as? Int) ?? 0) }
            let ys = vertices.map { ($0["y"] as? Double) ?? Double(($0["y"] as? Int) ?? 0) }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            return CGRect(x: minX / width, y: minY / height, width: max(maxX - minX, 1) / width,
                          height: max(maxY - minY, 1) / height)
        }

        var blocks: [PageText.Block] = []
        for block in page["blocks"] as? [[String: Any]] ?? [] {
            var lines: [PageText.Line] = []
            var text = ""
            var boxes: [CGRect] = []
            func endLine() {
                guard !text.isEmpty, let first = boxes.first else { return }
                let box = boxes.dropFirst().reduce(first) { $0.union($1) }
                lines.append(PageText.Line(text: text, box: box, characters: boxes))
                text = ""
                boxes = []
            }
            for paragraph in block["paragraphs"] as? [[String: Any]] ?? [] {
                for word in paragraph["words"] as? [[String: Any]] ?? [] {
                    for symbol in word["symbols"] as? [[String: Any]] ?? [] {
                        guard let character = symbol["text"] as? String, let box = rect(symbol) else { continue }
                        // One box per Character: a symbol is one grapheme.
                        text += character
                        boxes.append(contentsOf: Array(repeating: box, count: character.count))
                        let breakType = ((symbol["property"] as? [String: Any])?["detectedBreak"] as? [String: Any])?["type"] as? String
                        if breakType == "LINE_BREAK" || breakType == "EOL_SURE_SPACE" {
                            endLine()
                        }
                    }
                }
                endLine()
            }
            guard !lines.isEmpty else { continue }
            let longLines = lines.filter { $0.text.count > 1 }
            let vertical = longLines.isEmpty
                ? (rect(block).map { $0.height * height > $0.width * width } ?? true)
                : longLines.filter { $0.box.height * height > $0.box.width * width }.count * 2 >= longLines.count
            let ordered = vertical ? lines.sorted { $0.box.midX > $1.box.midX } : lines
            let box = rect(block) ?? ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            blocks.append(PageText.Block(box: box, vertical: vertical, lines: ordered))
        }
        return PageText(blocks: blocks)
    }
}
