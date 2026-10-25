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
    /// One per Character of `text`, same order.
    let characterBoxes: [CGRect]
    /// Lines whose characters run top to bottom (縦書き).
    let isVertical: Bool
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
    static func recognize(_ image: UIImage) async -> [OCRLine] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            recognize(cgImage: cgImage, orientation: orientation)
        }.value
    }

    private static func recognize(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false

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

            var boxes: [CGRect] = []
            boxes.reserveCapacity(text.count)
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(after: index)
                if let box = try? candidate.boundingBox(for: index..<next)?.boundingBox {
                    boxes.append(flip(box))
                } else {
                    boxes.append(.zero)
                }
                index = next
            }
            let lineBox = flip(observation.boundingBox)
            let vertical = text.count > 1 && lineBox.height > lineBox.width * 1.5
            lines.append(OCRLine(text: text, box: lineBox, characterBoxes: fillGaps(boxes, in: lineBox, vertical: vertical),
                                 isVertical: vertical))
        }
        return lines
    }

    /// Vision's origin is the bottom left; UIKit's is the top left.
    private static func flip(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// Characters Vision couldn't box get a share of the line instead.
    private static func fillGaps(_ boxes: [CGRect], in line: CGRect, vertical: Bool) -> [CGRect] {
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
