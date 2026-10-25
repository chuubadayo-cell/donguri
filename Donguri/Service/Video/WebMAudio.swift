//
//  WebMAudio.swift
//  Donguri
//
//  Card audio from what YouTube's player has buffered, when that is WebM
//  with Opus inside (what YouTube sends Safari). iOS can decode Opus but
//  can't open WebM, so the container is read here: the Opus packets and
//  their times come out of the Clusters, Apple's decoder turns them into
//  samples, and the line's stretch is cut and written as MP3.
//

import Foundation
import AVFoundation

nonisolated enum WebMAudio {
    nonisolated struct Packet {
        let time: Double
        let data: Data
    }

    nonisolated struct Parsed {
        var codec = ""
        var channels = 2
        var packets: [Packet] = []
    }

    /// The stretch [start, end] of a WebM init segment plus clusters, as
    /// an MP3 file; or nil, with what went wrong.
    static func clip(_ data: Data, start: Double, end: Double) async -> (url: URL?, note: String) {
        await Task.detached(priority: .userInitiated) { () -> (url: URL?, note: String) in
            let parsed = parse(data)
            guard parsed.codec == "A_OPUS" else { return (nil, "WebM codec \(parsed.codec.isEmpty ? "unknown" : parsed.codec)") }
            // From a little before the line, so the decoder has settled by
            // the time the line starts.
            let packets = parsed.packets.filter { $0.time >= start - 0.4 && $0.time < end + 0.1 }
            guard let first = packets.first else { return (nil, "no Opus packets in \(start)-\(end) (\(parsed.packets.count) in total)") }
            let decoded = decodeOpus(packets, channels: parsed.channels)
            guard let samples = decoded.samples else { return (nil, "Opus decoding failed: \(decoded.note)") }
            let rate = 48000.0
            let from = max(0, Int(((start - first.time) * rate).rounded()))
            let to = min(samples.count, Int(((end - first.time) * rate).rounded()))
            guard to > from else { return (nil, "nothing decoded for the line (\(samples.count) samples)") }
            guard let url = MP3Encoder.write(mono: Array(samples[from..<to]), rate: 48000) else {
                return (nil, "MP3 encoding failed")
            }
            return (url, "")
        }.value
    }

    // MARK: Container

    /// Master elements read into rather than over: Segment, Cluster,
    /// BlockGroup, Info, Tracks, TrackEntry, Audio.
    private static let masters: Set<UInt32> = [0x1853_8067, 0x1F43_B675, 0xA0, 0x1549_A966, 0x1654_AE6B, 0xAE, 0xE1]

    /// Every Opus packet with its time in seconds. The elements are walked
    /// in order, so Clusters of unknown size (live streams) work too.
    static func parse(_ data: Data) -> Parsed {
        let b = [UInt8](data)
        var result = Parsed()
        var timecodeScale: UInt64 = 1_000_000
        var clusterTime: UInt64 = 0
        var trackNumber: UInt64?
        var audioTrack: UInt64?
        var p = 0
        while p < b.count {
            guard let (id, idLength) = readID(b, p),
                  let (size, sizeLength, unknown) = readSize(b, p + idLength) else { break }
            let body = p + idLength + sizeLength
            if masters.contains(id) {
                p = body
                continue
            }
            guard !unknown, size <= UInt64(b.count - body) else { break }
            let end = body + Int(size)
            switch id {
            case 0x2A_D7B1:
                timecodeScale = readUInt(b, body, end)
            case 0xE7:
                clusterTime = readUInt(b, body, end)
            case 0xD7:
                trackNumber = readUInt(b, body, end)
            case 0x86:
                let codec = String(decoding: b[body..<end], as: UTF8.self)
                if codec.hasPrefix("A_") {
                    result.codec = codec
                    audioTrack = trackNumber
                }
            case 0x9F:
                result.channels = max(1, Int(readUInt(b, body, end)))
            case 0xA3, 0xA1:
                // (Simple)Block: track number, a signed 16-bit time from the
                // cluster's, flags, then the frame (Opus here isn't laced).
                guard let (track, trackLength, _) = readSize(b, body), body + trackLength + 3 <= end else { break }
                let relative = Int16(bitPattern: UInt16(b[body + trackLength]) << 8 | UInt16(b[body + trackLength + 1]))
                let flags = b[body + trackLength + 2]
                guard flags & 0x06 == 0, audioTrack == nil || track == audioTrack else { break }
                let ticks = Double(clusterTime) + Double(relative)
                let frame = Data(b[(body + trackLength + 3)..<end])
                if !frame.isEmpty {
                    result.packets.append(Packet(time: ticks * Double(timecodeScale) / 1e9, data: frame))
                }
            default:
                break
            }
            p = end
        }
        result.packets.sort { $0.time < $1.time }
        return result
    }

    private static func readID(_ b: [UInt8], _ p: Int) -> (UInt32, Int)? {
        guard p < b.count else { return nil }
        let first = b[p]
        let length = first >= 0x80 ? 1 : first >= 0x40 ? 2 : first >= 0x20 ? 3 : first >= 0x10 ? 4 : 0
        guard length > 0, p + length <= b.count else { return nil }
        var id: UInt32 = 0
        for index in 0..<length { id = id << 8 | UInt32(b[p + index]) }
        return (id, length)
    }

    /// An element size: the value, its length, and whether it's "unknown".
    private static func readSize(_ b: [UInt8], _ p: Int) -> (UInt64, Int, Bool)? {
        guard p < b.count else { return nil }
        let first = b[p]
        var length = 1
        var mask: UInt8 = 0x80
        while length <= 8, first & mask == 0 {
            mask >>= 1
            length += 1
        }
        guard length <= 8, p + length <= b.count else { return nil }
        var value = UInt64(first & (mask &- 1))
        var unknown = value == UInt64(mask &- 1)
        if length > 1 {
            for index in 1..<length {
                value = value << 8 | UInt64(b[p + index])
                if b[p + index] != 0xFF { unknown = false }
            }
        }
        return (value, length, unknown)
    }

    private static func readUInt(_ b: [UInt8], _ start: Int, _ end: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in start..<min(end, start + 8) { value = value << 8 | UInt64(b[index]) }
        return value
    }

    // MARK: Opus

    /// Samples per channel in an Opus packet, from its TOC byte (RFC 6716).
    static func frameCount(_ packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let durations: [Double]
        if config < 12 {
            durations = [10, 20, 40, 60]
        } else if config < 16 {
            durations = [10, 20]
        } else {
            durations = [2.5, 5, 10, 20]
        }
        let milliseconds = durations[config % durations.count]
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = packet.count > 1 ? Int(packet[packet.startIndex + 1] & 0x3F) : 1
        }
        return Int(milliseconds * 48) * frames
    }

    /// Mono samples at 48 kHz from the first packet on.
    private static func decodeOpus(_ packets: [Packet], channels: Int) -> (samples: [Float]?, note: String) {
        let frames = packets.map { frameCount($0.data) }
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frames.first ?? 960), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let inputFormat = AVAudioFormat(streamDescription: &description) else { return (nil, "no Opus format") }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                               channels: AVAudioChannelCount(channels), interleaved: false) else {
            return (nil, "no PCM format")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return (nil, "no Opus decoder") }

        let maximumSize = packets.map(\.data.count).max() ?? 0
        let input = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: AVAudioPacketCount(packets.count),
                                            maximumPacketSize: maximumSize)
        let bytes = input.data.assumingMemoryBound(to: UInt8.self)
        var offset = 0
        for (index, packet) in packets.enumerated() {
            packet.data.copyBytes(to: bytes + offset, count: packet.data.count)
            input.packetDescriptions?[index] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset), mVariableFramesInPacket: UInt32(frames[index]),
                mDataByteSize: UInt32(packet.data.count))
            offset += packet.data.count
        }
        input.packetCount = AVAudioPacketCount(packets.count)
        input.byteLength = UInt32(offset)

        let total = frames.reduce(0, +)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(total + 48000)) else {
            return (nil, "no output buffer")
        }
        let feeder = InputFeeder(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: feeder.next)
        guard status != .error, output.frameLength > 0, let data = output.floatChannelData else {
            return (nil, "status \(status.rawValue), \(output.frameLength) frames, \(error?.localizedDescription ?? "no error")")
        }
        let count = Int(output.frameLength)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channels {
            let samples = data[channel]
            for index in 0..<count { mono[index] += samples[index] }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for index in 0..<count { mono[index] *= scale }
        }
        return (mono, "")
    }

    /// Hands the converter all the packets once, then says that was all.
    private nonisolated final class InputFeeder {
        private let buffer: AVAudioCompressedBuffer
        private var given = false

        init(_ buffer: AVAudioCompressedBuffer) { self.buffer = buffer }

        func next(_ count: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
    }
}
