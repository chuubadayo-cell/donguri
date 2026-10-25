//
//  ClipCapture.swift
//  Donguri
//
//  The media for a card mined from a subtitle line, as asbplayer makes it:
//  the line's audio and a screenshot or short GIF, covering the line's time
//  plus a little padding.
//
//  Local files are cut with AVFoundation directly. YouTube plays as an HLS
//  stream, which AVFoundation can't cut, so the audio is taken from the
//  stream's own segments (MPEG-TS, packed AAC or fragmented MP4 — whichever
//  YouTube serves) and the pictures from a second, muted player that plays
//  just that stretch.
//

import Foundation
import AVFoundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// What a mined card gets attached.
nonisolated struct CardMedia: Sendable {
    var imageURL: URL?
    var audioURL: URL?
}

/// Where a video comes from, for cutting clips out of it.
nonisolated enum ClipSource: Sendable, Hashable {
    case file(URL)
    case stream(URL)

    var url: URL {
        switch self {
        case .file(let url), .stream(let url): url
        }
    }
}

nonisolated enum ClipImageKind: String, CaseIterable, Sendable {
    case screenshot
    case gif
    case none
}

nonisolated enum ClipCapture {
    static let directory: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iroha-clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static func newFile(_ ext: String) -> URL {
        directory.appendingPathComponent("iroha_\(UUID().uuidString.prefix(12).lowercased()).\(ext)")
    }

    // MARK: Audio

    static func audio(from source: ClipSource, start: Double, end: Double) async -> URL? {
        switch source {
        case .file(let url):
            return await exportAudio(asset: AVURLAsset(url: url), range: start...end)
        case .stream(let url):
            return try? await HLSAudio.clip(playlist: url, start: start, end: end)
        }
    }

    /// An asset's audio (or a time range of it) as AAC in an .m4a.
    static func exportAudio(asset: AVAsset, range: ClosedRange<Double>?) async -> URL? {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let output = newFile("m4a")
        if let range {
            session.timeRange = CMTimeRange(start: CMTime(seconds: max(0, range.lowerBound), preferredTimescale: 600),
                                            end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        }
        do {
            try await session.export(to: output, as: .m4a)
            return output
        } catch {
            return nil
        }
    }

    // MARK: Pictures

    static func image(from source: ClipSource, kind: ClipImageKind, start: Double, end: Double,
                      stillAt still: Double) async -> URL? {
        switch kind {
        case .none:
            return nil
        case .screenshot:
            guard let frame = await FrameGrabber.still(source: source, at: still) else { return nil }
            return writeJPEG(frame)
        case .gif:
            // Long lines are capped; a GIF of a whole minute helps no one.
            let length = min(end - start, 8)
            let fps: Double = length > 5 ? 6 : 8
            let frames = await FrameGrabber.frames(source: source, from: start, to: start + length, fps: fps)
            if frames.count > 1 {
                return writeGIF(frames, delay: 1 / fps)
            }
            if let only = frames.first { return writeJPEG(only) }
            if let only = await FrameGrabber.still(source: source, at: still) { return writeJPEG(only) }
            return nil
        }
    }

    static func writeJPEG(_ image: CGImage) -> URL? {
        let url = newFile("jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    static func writeGIF(_ frames: [CGImage], delay: Double) -> URL? {
        let url = newFile("gif")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    /// Scales an image down to `maxWidth`.
    static func scaled(_ image: CGImage, maxWidth: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        guard width > maxWidth else { return image }
        let scale = maxWidth / width
        let size = CGSize(width: (width * scale).rounded(), height: (CGFloat(image.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage() ?? image
    }
}

// MARK: - Frames

nonisolated enum FrameGrabber {
    static let stillWidth: CGFloat = 960
    static let gifWidth: CGFloat = 400

    static func still(source: ClipSource, at time: Double) async -> CGImage? {
        switch source {
        case .file(let url):
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: stillWidth, height: stillWidth)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        case .stream(let url):
            return await StreamSampler.sample(url: url, from: time, to: time, fps: 1, maxWidth: stillWidth).first
        }
    }

    static func frames(source: ClipSource, from start: Double, to end: Double, fps: Double) async -> [CGImage] {
        switch source {
        case .file(let url):
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: gifWidth, height: gifWidth)
            let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            var times: [CMTime] = []
            var time = start
            while time < end {
                times.append(CMTime(seconds: time, preferredTimescale: 600))
                time += 1 / fps
            }
            var frames: [CGImage] = []
            for await result in generator.images(for: times) {
                if let image = try? result.image { frames.append(image) }
            }
            return frames
        case .stream(let url):
            return await StreamSampler.sample(url: url, from: start, to: end, fps: fps, maxWidth: gifWidth)
        }
    }
}

/// Plays a stretch of a stream in a hidden, muted player and keeps frames
/// as it goes. Faster than real time where the stream allows.
@MainActor
final class StreamSampler {
    static func sample(url: URL, from start: Double, to end: Double, fps: Double, maxWidth: CGFloat) async -> [CGImage] {
        await StreamSampler().run(url: url, from: start, to: end, fps: fps, maxWidth: maxWidth)
    }

    private func run(url: URL, from start: Double, to end: Double, fps: Double, maxWidth: CGFloat) async -> [CGImage] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: YouTubeClient.userAgent])
        let item = AVPlayerItem(asset: asset)
        // A small variant is plenty for a card and quick to load.
        item.preferredMaximumResolution = maxWidth > 500 ? CGSize(width: 1280, height: 720) : CGSize(width: 640, height: 360)
        item.preferredForwardBufferDuration = 2
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        let deadline = Date.now.addingTimeInterval(15 + (end - start) * 2)
        while item.status == .unknown, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard item.status == .readyToPlay else { return [] }
        _ = await player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600))

        var frames: [CGImage] = []
        var nextSample = start
        let single = end <= start
        player.playImmediately(atRate: single ? 1 : 2)
        while Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(Int(max(15, 250 / fps))))
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            let seconds = time.seconds
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
               seconds >= nextSample - 0.5 / fps {
                var image: CGImage?
                VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
                if let image {
                    frames.append(ClipCapture.scaled(image, maxWidth: maxWidth))
                    nextSample = max(nextSample, seconds) + 1 / fps
                    if single { break }
                }
            }
            if seconds >= end, !single { break }
        }
        return frames
    }
}

// MARK: - HLS audio

/// Cuts a stretch of audio out of an HLS stream by fetching only the
/// segments that cover it.
nonisolated enum HLSAudio {
    enum Failure: Error { case playlist, segments, empty }

    private struct Segment {
        let url: URL
        let start: Double
        let duration: Double
    }

    static func clip(playlist: URL, start: Double, end: Double) async throws -> URL {
        let mediaPlaylist = try await audioPlaylist(from: playlist)
        let (segments, initURL) = try await self.segments(in: mediaPlaylist)
        let needed = segments.filter { $0.start < end && $0.start + $0.duration > start }
        guard !needed.isEmpty else { throw Failure.segments }

        var datas: [Data] = []
        for segment in needed {
            datas.append(try await fetch(segment.url))
        }
        guard let first = datas.first, !first.isEmpty else { throw Failure.empty }

        if isTransportStream(first) || isPackedAudio(first) {
            var frames: [(data: Data, time: Double)] = []
            var basePTS: Double?
            for (index, data) in datas.enumerated() {
                let parsed = isTransportStream(data) ? TransportStream.aacFrames(data) : PackedAudio.aacFrames(data)
                guard let firstPTS = parsed.first?.time else { continue }
                if basePTS == nil {
                    basePTS = firstPTS - (needed[index].start - needed[0].start)
                }
                let base = basePTS ?? firstPTS
                for frame in parsed {
                    frames.append((frame.data, needed[0].start + (frame.time - base)))
                }
            }
            var adts = Data()
            for frame in frames where frame.time >= start - 0.02 && frame.time < end {
                adts.append(frame.data)
            }
            guard !adts.isEmpty else { throw Failure.empty }
            let raw = ClipCapture.newFile("aac")
            try adts.write(to: raw)
            if let m4a = await ClipCapture.exportAudio(asset: AVURLAsset(url: raw), range: nil) {
                try? FileManager.default.removeItem(at: raw)
                return m4a
            }
            return raw
        }

        // Fragmented MP4: the init segment and the fragments make a file
        // AVFoundation can read.
        var file = Data()
        if let initURL { file.append(try await fetch(initURL)) }
        for data in datas { file.append(data) }
        let joined = ClipCapture.newFile("mp4")
        try file.write(to: joined)
        defer { try? FileManager.default.removeItem(at: joined) }
        let asset = AVURLAsset(url: joined)
        var trackStart = 0.0
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let range = try? await track.load(.timeRange) {
            trackStart = range.start.seconds.isFinite ? range.start.seconds : 0
        }
        let offset = trackStart - needed[0].start
        guard let clip = await ClipCapture.exportAudio(asset: asset, range: (start + offset)...(end + offset)) else {
            throw Failure.empty
        }
        return clip
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(YouTubeClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.segments
        }
        return data
    }

    /// The audio-only rendition if there is one, else the smallest variant.
    private static func audioPlaylist(from url: URL) async throws -> URL {
        let text = String(decoding: try await fetch(url), as: UTF8.self)
        if text.contains("#EXTINF") { return url }
        let lines = text.components(separatedBy: .newlines)

        var audio: [(uri: String, isDefault: Bool, japanese: Bool)] = []
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") {
            guard let uri = attribute("URI", in: line) else { continue }
            audio.append((uri, attribute("DEFAULT", in: line) == "YES",
                          attribute("LANGUAGE", in: line)?.hasPrefix("ja") == true))
        }
        if let pick = audio.first(where: { $0.japanese }) ?? audio.first(where: { $0.isDefault }) ?? audio.first,
           let resolved = URL(string: pick.uri, relativeTo: url)?.absoluteURL {
            return resolved
        }

        var best: (bandwidth: Int, uri: String)?
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let bandwidth = Int(attribute("BANDWIDTH", in: line) ?? "") ?? .max
            guard let uri = lines.dropFirst(index + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { continue }
            if let codecs = attribute("CODECS", in: line), !codecs.contains("mp4a") { continue }
            if best == nil || bandwidth < best!.bandwidth { best = (bandwidth, uri) }
        }
        guard let best, let resolved = URL(string: best.uri, relativeTo: url)?.absoluteURL else { throw Failure.playlist }
        return resolved
    }

    private static func segments(in url: URL) async throws -> ([Segment], URL?) {
        let text = String(decoding: try await fetch(url), as: UTF8.self)
        var segments: [Segment] = []
        var initURL: URL?
        var time = 0.0
        var pendingDuration: Double?
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? ""
                pendingDuration = Double(value)
            } else if line.hasPrefix("#EXT-X-MAP:"), let uri = attribute("URI", in: line) {
                initURL = URL(string: uri, relativeTo: url)?.absoluteURL
            } else if !line.isEmpty, !line.hasPrefix("#"), let duration = pendingDuration {
                if let segmentURL = URL(string: line, relativeTo: url)?.absoluteURL {
                    segments.append(Segment(url: segmentURL, start: time, duration: duration))
                }
                time += duration
                pendingDuration = nil
            }
        }
        guard !segments.isEmpty else { throw Failure.playlist }
        return (segments, initURL)
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name + "=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.first == "\"" {
            let body = rest.dropFirst()
            guard let close = body.firstIndex(of: "\"") else { return nil }
            return String(body[..<close])
        }
        return String(rest.prefix { $0 != "," })
    }

    static func isTransportStream(_ data: Data) -> Bool {
        data.count >= 189 && data[data.startIndex] == 0x47 && data[data.startIndex + 188] == 0x47
    }

    static func isPackedAudio(_ data: Data) -> Bool {
        guard data.count > 4 else { return false }
        let bytes = [UInt8](data.prefix(3))
        if bytes == [0x49, 0x44, 0x33] { return true } // "ID3"
        return bytes[0] == 0xFF && (bytes[1] & 0xF0) == 0xF0
    }
}

/// AAC frames out of an MPEG transport stream, each with its time.
nonisolated enum TransportStream {
    static func aacFrames(_ data: Data) -> [(data: Data, time: Double)] {
        let bytes = [UInt8](data)
        var audioPID: Int?
        var elementary: [UInt8] = []
        var markers: [(offset: Int, pts: Double)] = []
        var index = 0
        while index + 188 <= bytes.count {
            defer { index += 188 }
            guard bytes[index] == 0x47 else { continue }
            let pid = (Int(bytes[index + 1] & 0x1F) << 8) | Int(bytes[index + 2])
            let unitStart = bytes[index + 1] & 0x40 != 0
            let adaptation = (bytes[index + 3] >> 4) & 0x03
            var payload = index + 4
            if adaptation == 2 { continue }
            if adaptation == 3 { payload += 1 + Int(bytes[index + 4]) }
            let packetEnd = index + 188
            guard payload < packetEnd else { continue }

            if unitStart, payload + 9 <= packetEnd,
               bytes[payload] == 0, bytes[payload + 1] == 0, bytes[payload + 2] == 1 {
                let streamID = bytes[payload + 3]
                if audioPID == nil, (0xC0...0xDF).contains(streamID) { audioPID = pid }
                guard pid == audioPID else { continue }
                let flags = bytes[payload + 7]
                let headerLength = Int(bytes[payload + 8])
                if flags & 0x80 != 0, payload + 14 <= packetEnd {
                    let p = payload + 9
                    let pts = (UInt64(bytes[p] & 0x0E) << 29) | (UInt64(bytes[p + 1]) << 22)
                        | (UInt64(bytes[p + 2] & 0xFE) << 14) | (UInt64(bytes[p + 3]) << 7)
                        | (UInt64(bytes[p + 4]) >> 1)
                    markers.append((elementary.count, Double(pts) / 90000))
                }
                let start = payload + 9 + headerLength
                if start < packetEnd { elementary.append(contentsOf: bytes[start..<packetEnd]) }
            } else if pid == audioPID {
                elementary.append(contentsOf: bytes[payload..<packetEnd])
            }
        }
        return ADTS.frames(elementary, markers: markers)
    }
}

/// Packed audio (an ID3 tag carrying the timestamp, then ADTS frames).
nonisolated enum PackedAudio {
    static func aacFrames(_ data: Data) -> [(data: Data, time: Double)] {
        let bytes = [UInt8](data)
        var offset = 0
        var pts = 0.0
        if bytes.count > 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            let size = (Int(bytes[6] & 0x7F) << 21) | (Int(bytes[7] & 0x7F) << 14)
                | (Int(bytes[8] & 0x7F) << 7) | Int(bytes[9] & 0x7F)
            let tagEnd = min(bytes.count, 10 + size)
            let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0]
            if let range = find(owner, in: bytes, before: tagEnd), range + 8 <= tagEnd {
                var value: UInt64 = 0
                for byte in bytes[range..<(range + 8)] { value = (value << 8) | UInt64(byte) }
                pts = Double(value & 0x1_FFFF_FFFF) / 90000
            }
            offset = tagEnd
        }
        return ADTS.frames(Array(bytes[offset...]), markers: [(0, pts)])
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], before end: Int) -> Int? {
        guard needle.count <= end else { return nil }
        var index = 0
        while index + needle.count <= end {
            if haystack[index] == needle[0], Array(haystack[index..<(index + needle.count)]) == needle {
                return index + needle.count
            }
            index += 1
        }
        return nil
    }
}

nonisolated enum ADTS {
    private static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// Splits an ADTS stream into frames, timing each from the nearest
    /// preceding timestamp marker.
    static func frames(_ bytes: [UInt8], markers: [(offset: Int, pts: Double)]) -> [(data: Data, time: Double)] {
        var frames: [(data: Data, time: Double)] = []
        var position = 0
        var markerIndex = 0
        var clock = markers.first?.pts ?? 0
        while position + 7 <= bytes.count {
            guard bytes[position] == 0xFF, bytes[position + 1] & 0xF0 == 0xF0 else {
                position += 1
                continue
            }
            let length = (Int(bytes[position + 3] & 0x03) << 11) | (Int(bytes[position + 4]) << 3) | (Int(bytes[position + 5]) >> 5)
            let rateIndex = Int((bytes[position + 2] >> 2) & 0x0F)
            guard length > 7, rateIndex < sampleRates.count, position + length <= bytes.count else { break }
            while markerIndex < markers.count, markers[markerIndex].offset <= position {
                clock = markers[markerIndex].pts
                markerIndex += 1
            }
            frames.append((Data(bytes[position..<(position + length)]), clock))
            clock += 1024 / Double(sampleRates[rateIndex])
            position += length
        }
        return frames
    }
}
