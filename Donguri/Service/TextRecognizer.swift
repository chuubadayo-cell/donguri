//
//  TextRecognizer.swift
//  Donguri
//
//  On-device text recognition (OCR) with Apple's Vision framework, in the
//  spirit of MaruReader's manga and photo scanning: find the Japanese text
//  in an image, keep where every character is, so a tap on a character can
//  be looked up exactly like a tap on post text.
//

import Foundation
import Vision
import UIKit

/// One recognised line, with the box of every character in it. Boxes are
/// normalised to the image (0…1), origin at the top left.
nonisolated struct OCRLine: Sendable, Hashable {
    let text: String
    let box: CGRect
    /// Lines whose characters run top to bottom (縦書き).
    let isVertical: Bool
    /// Asking Vision where each character is costs about as much as the
    /// recognition itself on a text-heavy image, so it is done only for a
    /// line that is actually tapped, and remembered.
    fileprivate let characters: OCRCharacterBoxes

    /// One per Character of `text`, same order.
    var characterBoxes: [CGRect] { characters.boxes(line: box, vertical: isVertical) }

    static func == (lhs: OCRLine, rhs: OCRLine) -> Bool {
        lhs.text == rhs.text && lhs.box == rhs.box
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(box.minX)
        hasher.combine(box.minY)
    }
}

/// Vision's recognised text for one line, asked for character boxes on
/// demand. Vision's objects are immutable once the request has finished;
/// the lock guards the cache.
nonisolated final class OCRCharacterBoxes: @unchecked Sendable {
    private let candidate: VNRecognizedText
    private let lock = NSLock()
    private var cached: [CGRect]?

    init(candidate: VNRecognizedText) {
        self.candidate = candidate
    }

    func boxes(line: CGRect, vertical: Bool) -> [CGRect] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let text = candidate.string
        var boxes: [CGRect] = []
        boxes.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if let box = try? candidate.boundingBox(for: index..<next)?.boundingBox {
                boxes.append(TextRecognizer.flip(box))
            } else {
                boxes.append(.zero)
            }
            index = next
        }
        let filled = TextRecognizer.fillGaps(boxes, in: line, vertical: vertical)
        cached = filled
        return filled
    }
}

/// What a tap on recognised text found.
nonisolated struct OCRHit: Sendable {
    /// From the tapped character to the end of its line, for the lookup.
    let text: String
    /// The whole line, as the sentence for Anki.
    let sentence: String
    /// The tapped character, normalised to the image.
    let characterBox: CGRect
}

nonisolated enum TextRecognizer {
    /// Recognises the text in `image`. Runs off the main thread.
    static func recognize(_ image: UIImage, priority: TaskPriority = .userInitiated) async -> [OCRLine] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: priority) {
            recognize(cgImage: cgImage, orientation: orientation)
        }.value
    }

    /// Loads Vision's Japanese models ahead of the first real request,
    /// which otherwise waits for them (most of a second).
    static func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        Task.detached(priority: .utility) {
            let size = CGSize(width: 64, height: 32)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                ("あ" as NSString).draw(at: CGPoint(x: 20, y: 4), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
            if let cgImage = image.cgImage {
                _ = recognize(cgImage: cgImage, orientation: .up)
            }
        }
    }

    private nonisolated(unsafe) static var warmedUp = false

    private static func recognize(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false
        // Specks and noise smaller than this aren't text worth tapping.
        request.minimumTextHeight = 0.008

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        var lines: [OCRLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let lineBox = flip(observation.boundingBox)
            let vertical = text.count > 1 && lineBox.height > lineBox.width * 1.5
            lines.append(OCRLine(text: text, box: lineBox, isVertical: vertical,
                                 characters: OCRCharacterBoxes(candidate: candidate)))
        }
        return lines
    }

    /// Vision's origin is the bottom left; UIKit's is the top left.
    fileprivate static func flip(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// Characters Vision couldn't box get a share of the line instead.
    fileprivate static func fillGaps(_ boxes: [CGRect], in line: CGRect, vertical: Bool) -> [CGRect] {
        guard boxes.contains(where: { $0 == .zero }), !boxes.isEmpty else { return boxes }
        let count = CGFloat(boxes.count)
        return boxes.enumerated().map { index, box in
            guard box == .zero else { return box }
            let i = CGFloat(index)
            if vertical {
                return CGRect(x: line.minX, y: line.minY + line.height * i / count,
                              width: line.width, height: line.height / count)
            }
            return CGRect(x: line.minX + line.width * i / count, y: line.minY,
                          width: line.width / count, height: line.height)
        }
    }

    /// The text at a normalised point, or nil if the point isn't on text.
    static func hit(at point: CGPoint, in lines: [OCRLine], maxLength: Int = 16) -> OCRHit? {
        // A little slack around each box: fingers are wider than characters.
        let slack: CGFloat = 0.006
        for line in lines where line.box.insetBy(dx: -slack, dy: -slack).contains(point) {
            let characters = Array(line.text)
            var best: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (index, box) in line.characterBoxes.enumerated() where index < characters.count {
                if box.insetBy(dx: -slack, dy: -slack).contains(point) {
                    best = index
                    break
                }
                let distance = hypot(box.midX - point.x, box.midY - point.y)
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            guard let start = best else { continue }
            var scanned = ""
            for character in characters[start...] {
                guard let scalar = character.unicodeScalars.first,
                      !PostTextScanner.isScanBoundary(scalar, scanNonJapanese: true) else { break }
                scanned.append(character)
                if scanned.count >= maxLength { break }
            }
            guard !scanned.isEmpty else { continue }
            return OCRHit(text: scanned, sentence: line.text, characterBox: line.characterBoxes[start])
        }
        return nil
    }
}

extension CGImagePropertyOrientation {
    nonisolated init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// A small JPEG of an image, for attaching to Anki cards.
enum CardImage {
    static func write(_ image: UIImage, maxSide: CGFloat = 720) -> URL? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: 0.7) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iroha-card-\(UUID().uuidString.prefix(8)).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
