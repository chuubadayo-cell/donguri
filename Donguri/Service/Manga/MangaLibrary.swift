//
//  MangaLibrary.swift
//  Donguri
//
//  Manga saved from sources, and where reading stopped: the page in each
//  chapter or volume, and the last chapter opened in each manga. A JSON
//  file under Application Support, written a moment after each change.
//

import Foundation
import AidokuRunner

struct SavedManga: Codable, Identifiable, Hashable {
    let sourceKey: String
    var manga: AidokuRunner.Manga
    var added = Date()

    var id: String { MangaLibrary.mangaID(source: sourceKey, manga: manga.key) }
}

@Observable
final class MangaLibrary {
    static let shared = MangaLibrary()

    private struct Stored: Codable {
        var saved: [SavedManga] = []
        /// Reading-unit id → page index.
        var pages: [String: Int] = [:]
        /// Manga id → the chapter key last opened.
        var lastChapter: [String: String] = [:]
        /// Reading-unit ids read to the end.
        var finished: Set<String> = []
    }

    private var stored = Stored()
    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "MangaLibrary.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        }
    }

    static func mangaID(source: String, manga: String) -> String { "\(source)\u{1F}\(manga)" }
    static func chapterID(source: String, manga: String, chapter: String) -> String {
        "\(source)\u{1F}\(manga)\u{1F}\(chapter)"
    }

    var saved: [SavedManga] { stored.saved.sorted { $0.added > $1.added } }

    func isSaved(source: String, manga: String) -> Bool {
        stored.saved.contains { $0.sourceKey == source && $0.manga.key == manga }
    }

    func toggleSaved(source: String, manga: AidokuRunner.Manga) {
        if let index = stored.saved.firstIndex(where: { $0.sourceKey == source && $0.manga.key == manga.key }) {
            stored.saved.remove(at: index)
        } else {
            var copy = manga
            copy.chapters = nil
            stored.saved.append(SavedManga(sourceKey: source, manga: copy))
        }
        scheduleSave()
    }

    /// Keeps a saved manga's details current after it's been refreshed.
    func update(source: String, manga: AidokuRunner.Manga) {
        guard let index = stored.saved.firstIndex(where: { $0.sourceKey == source && $0.manga.key == manga.key }) else { return }
        var copy = manga
        copy.chapters = nil
        if stored.saved[index].manga != copy {
            stored.saved[index].manga = copy
            scheduleSave()
        }
    }

    func page(for unit: String) -> Int { stored.pages[unit] ?? 0 }

    func isFinished(_ unit: String) -> Bool { stored.finished.contains(unit) }

    func setPage(_ page: Int, of count: Int, for unit: String) {
        guard stored.pages[unit] != page else { return }
        stored.pages[unit] = page
        if count > 0, page >= count - 1 { stored.finished.insert(unit) }
        scheduleSave()
    }

    func lastChapter(for mangaID: String) -> String? { stored.lastChapter[mangaID] }

    func setLastChapter(_ chapter: String, for mangaID: String) {
        guard stored.lastChapter[mangaID] != chapter else { return }
        stored.lastChapter[mangaID] = chapter
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    func flush() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
