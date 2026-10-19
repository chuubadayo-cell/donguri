//
//  DatCache.swift
//  Donguri
//
//  Keeps each thread's raw .dat on disk so that reopening or refreshing a
//  thread only downloads what was added since last time (差分取得), the way
//  dedicated 5ch browsers do. A 1000-post thread is a few hundred kilobytes;
//  a refresh with three new replies is now a few hundred bytes.
//
//  How it works: the request asks for the cached file's size minus one byte
//  onward (`Range: bytes=N-1-`). If the server sends back exactly the byte we
//  already had last (always a newline) followed by new data, the two are
//  joined. Anything else, e.g. the file shrank because a post was deleted
//  (あぼーん), falls back to downloading the whole file again.
//
//  Lives in Caches, so iOS may clear it when space is low; that only costs a
//  full download next time.
//

import Foundation
import CryptoKit

actor DatCache {
    nonisolated static let shared = DatCache()

    nonisolated enum FetchError: Error {
        case notFound
    }

    private nonisolated struct Meta: Codable {
        var lastModified: String?
    }

    private let folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = caches.appendingPathComponent("DatCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// The whole .dat, downloading only the new part when possible.
    func fetch(_ url: URL) async throws -> Data {
        let cached = load(url)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let cached, cached.data.count > 1, cached.data.last == 0x0A {
            request.setValue("bytes=\(cached.data.count - 1)-", forHTTPHeaderField: "Range")
            // A compressed response would make byte offsets meaningless.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let lastModified = cached.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")

        switch http.statusCode {
        case 200:
            store(data, lastModified: lastModified, for: url)
            return data
        case 206:
            guard let cached, data.first == 0x0A else {
                return try await fetchWhole(url)
            }
            var merged = cached.data
            merged.append(data.dropFirst())
            store(merged, lastModified: lastModified ?? cached.lastModified, for: url)
            return merged
        case 304:
            if let cached { return cached.data }
            return try await fetchWhole(url)
        case 416:
            // The file is shorter than our copy: something was deleted.
            return try await fetchWhole(url)
        case 404:
            throw FetchError.notFound
        default:
            throw URLError(.badServerResponse)
        }
    }

    /// Whatever is on disk for this thread, without touching the network.
    func cachedData(for url: URL) -> Data? {
        load(url)?.data
    }

    func clear() {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func fetchWhole(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode != 404 else { throw FetchError.notFound }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        store(data, lastModified: http.value(forHTTPHeaderField: "Last-Modified"), for: url)
        return data
    }

    private func paths(for url: URL) -> (dat: URL, meta: URL)? {
        guard let folder else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return (folder.appendingPathComponent(name + ".dat"),
                folder.appendingPathComponent(name + ".json"))
    }

    private func load(_ url: URL) -> (data: Data, lastModified: String?)? {
        guard let paths = paths(for: url),
              let data = try? Data(contentsOf: paths.dat),
              !data.isEmpty else { return nil }
        let meta = (try? Data(contentsOf: paths.meta)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        return (data, meta?.lastModified)
    }

    private func store(_ data: Data, lastModified: String?, for url: URL) {
        guard let paths = paths(for: url), !data.isEmpty else { return }
        try? data.write(to: paths.dat, options: .atomic)
        if let meta = try? JSONEncoder().encode(Meta(lastModified: lastModified)) {
            try? meta.write(to: paths.meta, options: .atomic)
        }
    }
}
