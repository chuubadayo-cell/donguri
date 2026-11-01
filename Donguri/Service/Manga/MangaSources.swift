//
//  MangaSources.swift
//  Donguri
//
//  Aidoku's manga sources: source lists (Aidoku's index format, added by
//  URL), installing a source's package, and running installed sources with
//  AidokuRunner (Skittyblock's runner, used unmodified as a package; it is
//  source-available, not GPL, so it stays a dependency and is never copied
//  in). Only current-format sources load; Aidoku's legacy ones don't.
//

import Foundation
import AidokuRunner
import ZIPFoundation

/// One source as a source list describes it.
nonisolated struct MangaSourceListing: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: Int
    let iconURL: String?
    let downloadURL: String?
    let languages: [String]?
    let contentRating: Int?
    // The older index format's names for the same things.
    let lang: String?
    let nsfw: Int?
    let file: String?
    let icon: String?

    /// The list it came from, which relative paths are resolved against.
    var listURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, name, version, iconURL, downloadURL, languages, contentRating, lang, nsfw, file, icon
    }

    var packageURL: URL? {
        guard let listURL else { return nil }
        if let downloadURL { return URL(string: downloadURL, relativeTo: listURL)?.absoluteURL }
        if let file { return URL(string: "sources/\(file)", relativeTo: listURL)?.absoluteURL }
        return nil
    }

    var iconImageURL: URL? {
        guard let listURL else { return nil }
        if let iconURL { return URL(string: iconURL, relativeTo: listURL)?.absoluteURL }
        if let icon { return URL(string: "icons/\(icon)", relativeTo: listURL)?.absoluteURL }
        return nil
    }

    var languageList: [String] { languages ?? lang.map { [$0] } ?? [] }

    var isNSFW: Bool { (contentRating ?? nsfw ?? 0) > 0 }
}

nonisolated struct MangaSourceList: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let sources: [MangaSourceListing]
}

private nonisolated struct CodableSourceList: Decodable {
    let name: String
    let sources: [MangaSourceListing]
}

@Observable
final class MangaSources {
    static let shared = MangaSources()

    private static let listsKey = "iroha.manga.sourceLists"

    /// The source lists' addresses, as added.
    private(set) var listURLs: [URL]
    private(set) var lists: [MangaSourceList] = []
    private(set) var listErrors: [URL: String] = [:]
    private(set) var isLoadingLists = false
    /// Installed and running, by key.
    private(set) var installed: [String: AidokuRunner.Source] = [:]
    /// Keys being installed right now.
    private(set) var installing: Set<String> = []

    private var loadedInstalled = false

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "MangaSources", directoryHint: .isDirectory)
    }

    private init() {
        listURLs = (UserDefaults.standard.stringArray(forKey: Self.listsKey) ?? []).compactMap(URL.init(string:))
    }

    var installedSources: [AidokuRunner.Source] {
        installed.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Lists

    func addList(_ string: String) async -> Bool {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), url.host() != nil else { return false }
        guard !listURLs.contains(url) else { return true }
        guard let list = await Self.fetchList(url) else { return false }
        listURLs.append(url)
        saveLists()
        lists.removeAll { $0.url == url }
        lists.append(list)
        return true
    }

    func removeList(_ url: URL) {
        listURLs.removeAll { $0 == url }
        lists.removeAll { $0.url == url }
        listErrors[url] = nil
        saveLists()
    }

    func refreshLists() async {
        guard !isLoadingLists else { return }
        isLoadingLists = true
        defer { isLoadingLists = false }
        var loaded: [MangaSourceList] = []
        var errors: [URL: String] = [:]
        await withTaskGroup(of: (URL, MangaSourceList?).self) { group in
            for url in listURLs {
                group.addTask { (url, await Self.fetchList(url)) }
            }
            for await (url, list) in group {
                if let list { loaded.append(list) } else { errors[url] = String(localized: "読み込めませんでした") }
            }
        }
        lists = listURLs.compactMap { url in loaded.first { $0.url == url } }
        listErrors = errors
    }

    /// The newest version of each source across all lists.
    var availableSources: [MangaSourceListing] {
        var byID: [String: MangaSourceListing] = [:]
        for list in lists {
            for source in list.sources where (byID[source.id]?.version ?? -1) < source.version {
                byID[source.id] = source
            }
        }
        return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func saveLists() {
        UserDefaults.standard.set(listURLs.map(\.absoluteString), forKey: Self.listsKey)
    }

    /// A list is either `{name, sources}` or, in the older format, a bare
    /// array (at the URL, or in its index.min.json).
    @concurrent
    private nonisolated static func fetchList(_ url: URL) async -> MangaSourceList? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        let decoder = JSONDecoder()
        if let list = try? decoder.decode(CodableSourceList.self, from: data) {
            return MangaSourceList(url: url, name: list.name, sources: list.sources.map { with($0, list: url) })
        }
        if let sources = try? decoder.decode([MangaSourceListing].self, from: data) {
            return MangaSourceList(url: url, name: url.host() ?? url.absoluteString,
                                   sources: sources.map { with($0, list: url) })
        }
        let index = url.appending(path: "index.min.json")
        if let (indexData, _) = try? await session.data(from: index),
           let sources = try? decoder.decode([MangaSourceListing].self, from: indexData) {
            let base = url.absoluteString.hasSuffix("/") ? url : URL(string: url.absoluteString + "/") ?? url
            return MangaSourceList(url: url, name: url.host() ?? url.absoluteString,
                                   sources: sources.map { with($0, list: base) })
        }
        return nil
    }

    private nonisolated static func with(_ source: MangaSourceListing, list: URL) -> MangaSourceListing {
        var copy = source
        copy.listURL = list
        return copy
    }

    // MARK: Installed sources

    /// Starts every installed source. Cheap to call again.
    func loadInstalled() async {
        guard !loadedInstalled else { return }
        loadedInstalled = true
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.hasDirectoryPath {
            let key = folder.lastPathComponent
            if let source = try? await AidokuRunner.Source(url: folder, interpreterConfig: Self.config(for: key)) {
                installed[source.key] = source
            }
        }
    }

    func install(_ listing: MangaSourceListing) async throws {
        guard let url = listing.packageURL else { throw MangaSourceError.badPackage }
        installing.insert(listing.id)
        defer { installing.remove(listing.id) }
        let (location, _) = try await URLSession.shared.download(from: url)
        let temporary = FileManager.default.temporaryDirectory.appending(path: "source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.unzipItem(at: location, to: temporary)
        let payload = temporary.appending(path: "Payload", directoryHint: .isDirectory)
        // Loading it once checks it's a source this runner understands.
        let probe: AidokuRunner.Source
        do {
            probe = try await AidokuRunner.Source(url: payload)
        } catch {
            throw MangaSourceError.unsupported
        }
        let key = probe.key
        guard !key.isEmpty, !key.contains("/"), !key.hasPrefix(".") else { throw MangaSourceError.badPackage }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let destination = Self.directory.appending(path: key, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: payload, to: destination)
        installed[key] = try await AidokuRunner.Source(url: destination, interpreterConfig: Self.config(for: key))
    }

    func uninstall(_ key: String) {
        installed[key] = nil
        try? FileManager.default.removeItem(at: Self.directory.appending(path: key, directoryHint: .isDirectory))
    }

    func installedVersion(of id: String) -> Int? {
        installed[id]?.version
    }

    // MARK: Requests

    /// Sources' requests carry Safari's user agent and the cookies the
    /// app's browser has, as Aidoku's do.
    private nonisolated static func config(for key: String) -> InterpreterConfiguration {
        InterpreterConfiguration(
            printHandler: { message in
                #if DEBUG
                print("[manga:\(key)] \(message)")
                #endif
            },
            requestHandler: { request in
                try await URLSession.shared.data(for: prepared(request))
            }
        )
    }

    nonisolated static func prepared(_ original: URLRequest) -> URLRequest {
        var request = original
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(SafariUserAgent.mobile, forHTTPHeaderField: "User-Agent")
        }
        if let url = request.url, let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
            if let existing = request.value(forHTTPHeaderField: "Cookie"), !existing.isEmpty {
                request.setValue(header + "; " + existing, forHTTPHeaderField: "Cookie")
            } else if !header.isEmpty {
                request.setValue(header, forHTTPHeaderField: "Cookie")
            }
        }
        return request
    }
}

enum MangaSourceError: LocalizedError {
    case badPackage
    case unsupported
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .badPackage: String(localized: "ソースのファイルが読めませんでした")
        case .unsupported: String(localized: "このソースは古い形式で、対応していません")
        case .notInstalled: String(localized: "ソースがインストールされていません")
        }
    }
}
