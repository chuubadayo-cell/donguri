//
//  MP3Encoder.swift
//  Donguri
//
//  Card audio as MP3, which every Anki plays and downloads: AnkiMobile
//  only fetches media whose link ends in an extension it knows. iOS can
//  read almost anything but can't write MP3, so the audio is decoded here
//  and encoded with shine (Vendor/shine).
//

import Foundation
import AVFoundation

nonisolated enum MP3Encoder {
    static let sampleRate: Double = 44100
    static let bitrate: Int32 = 128

    /// An MP3 copy of any audio file AVFoundation can read, or nil.
    static func encode(_ source: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            encodeNow(source)
        }.value
    }

    private static func encodeNow(_ source: URL) -> URL? {
        guard let audio = pcm(from: source), !audio.samples.isEmpty else { return nil }
        var size = 0
        let buffer: UnsafeMutablePointer<UInt8>? = audio.samples.withUnsafeBufferPointer { pointer in
            iroha_mp3_encode_mono(pointer.baseAddress, pointer.count, Int32(audio.rate), bitrate, &size)
        }
        guard let buffer, size > 0 else { return nil }
        defer { iroha_mp3_free(buffer) }
        let output = ClipCapture.newFile("mp3")
        do {
            try Data(bytes: buffer, count: size).write(to: output)
            return output
        } catch {
            return nil
        }
    }

    /// The loudest sample in a file (0...1), or nil if it can't be read.
    /// A recording of silence peaks near zero.
    static func peak(_ url: URL) async -> Float? {
        await Task.detached(priority: .userInitiated) {
            guard let audio = pcm(from: url) else { return nil }
            var loudest: Int16 = 0
            for sample in audio.samples {
                let level = sample == .min ? .max : abs(sample)
                if level > loudest { loudest = level }
            }
            return Float(loudest) / 32767
        }.value
    }

    /// Rates MP3 (and shine) can take as they are.
    private static let mp3Rates = [44100, 48000, 32000, 22050, 24000, 16000]

    /// The file's audio as mono 16-bit samples, at its own rate when MP3
    /// supports it and otherwise resampled to 44.1 kHz.
    private static func pcm(from url: URL) -> (samples: [Int16], rate: Int)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return nil }

        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for index in 0..<count { mono[index] += data[index] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for index in 0..<count { mono[index] *= scale }
        }

        var rate = Int(format.sampleRate.rounded())
        if !mp3Rates.contains(rate) {
            // Linear resampling; plenty for speech.
            let ratio = format.sampleRate / sampleRate
            let outCount = Int(Double(count) / ratio)
            var resampled = [Float](repeating: 0, count: outCount)
            for index in 0..<outCount {
                let position = Double(index) * ratio
                let low = Int(position)
                let high = min(low + 1, count - 1)
                let fraction = Float(position - Double(low))
                resampled[index] = mono[low] * (1 - fraction) + mono[high] * fraction
            }
            mono = resampled
            rate = Int(sampleRate)
        }
        let samples = mono.map { Int16(max(-1, min(1, $0)) * 32767) }
        return (samples, rate)
    }
}
