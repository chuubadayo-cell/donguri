//
//  MangaLibrary.swift
//  Donguri
//
//  The manga library: titles saved from sources and series from the Manga
//  folder, sorted onto shelves the user makes; and where reading stopped:
//  the page in each chapter or volume (with its page count, for progress
//  bars), the chapters read to the end, the last chapter opened and when
//  each title was last read. A JSON file under Application Support,
//  written a moment after each change.
//

import Foundation
import AidokuRunner
import SwiftUI

struct SavedManga: Codable, Identifiable, Hashable {
    let sourceKey: String
    var manga: AidokuRunner.Manga
    var added = Date()
    /// The chapters as last seen, for the progress bar.
    var chapterKeys: [String]?
    var shelves: Set<UUID>?

    var id: String { MangaLibrary.mangaID(source: sourceKey, manga: manga.key) }
}

/// A series from the Manga folder put in the library.
struct SavedLocalSeries: Codable, Identifiable, Hashable {
    let seriesID: String
    var title: String
    var added = Date()
    var shelves: Set<UUID>?

    var id: String { MangaLibrary.localID(seriesID) }
}

struct MangaShelf: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

/// One title in the library, from a source or the Manga folder.
struct LibraryEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case source(key: String, manga: AidokuRunner.Manga)
        case local(seriesID: String)
    }

    let id: String
    let title: String
    let kind: Kind
    let added: Date
    let lastRead: Date?
    let shelves: Set<UUID>
}

@Observable
final class MangaLibrary {
    static let shared = MangaLibrary()

    private struct Stored: Codable {
        var saved: [SavedManga] = []
        var localSaved: [SavedLocalSeries]?
        var shelves: [MangaShelf]?
        /// Reading-unit id → page index.
        var pages: [String: Int] = [:]
        /// Reading-unit id → how many pages it has.
        var pageCounts: [String: Int]?
        /// Manga id → the chapter key last opened.
        var lastChapter: [String: String] = [:]
        /// Reading-unit ids read to the end.
        var finished: Set<String> = []
        /// Library entry id → when it was last read.
        var lastRead: [String: Date]?
        /// Library entry id → the name the user gave it.
        var names: [String: String]?
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
    /// A local series' library id; also the reader's series id for it.
    static func localID(_ seriesID: String) -> String { "local\u{1F}\(seriesID)" }

    // MARK: Entries

    var saved: [SavedManga] { stored.saved.sorted { $0.added > $1.added } }

    /// Everything in the library, most recently read (or added) first.
    var entries: [LibraryEntry] {
        let lastRead = stored.lastRead ?? [:]
        let fromSources = stored.saved.map { item in
            LibraryEntry(id: item.id, title: name(item.id) ?? item.manga.title, kind: .source(key: item.sourceKey, manga: item.manga),
                         added: item.added, lastRead: lastRead[item.id], shelves: item.shelves ?? [])
        }
        let local = (stored.localSaved ?? []).map { item in
            LibraryEntry(id: item.id, title: name(item.id) ?? item.title, kind: .local(seriesID: item.seriesID),
                         added: item.added, lastRead: lastRead[item.id], shelves: item.shelves ?? [])
        }
        return (fromSources + local).sorted { ($0.lastRead ?? $0.added) > ($1.lastRead ?? $1.added) }
    }

    func isSaved(source: String, manga: String) -> Bool {
        stored.saved.contains { $0.sourceKey == source && $0.manga.key == manga }
    }

    func isSaved(local seriesID: String) -> Bool {
        (stored.localSaved ?? []).contains { $0.seriesID == seriesID }
    }

    func toggleSaved(source: String, manga: AidokuRunner.Manga) {
        if let index = stored.saved.firstIndex(where: { $0.sourceKey == source && $0.manga.key == manga.key }) {
            stored.saved.remove(at: index)
        } else {
            var copy = manga
            let keys = copy.chapters?.map(\.key)
            copy.chapters = nil
            stored.saved.append(SavedManga(sourceKey: source, manga: copy, chapterKeys: keys))
        }
        scheduleSave()
    }

    func toggleSaved(local series: LocalSeries) {
        var list = stored.localSaved ?? []
        if let index = list.firstIndex(where: { $0.seriesID == series.id }) {
            list.remove(at: index)
        } else {
            list.append(SavedLocalSeries(seriesID: series.id, title: series.title))
        }
        stored.localSaved = list
        scheduleSave()
    }

    func remove(_ entry: LibraryEntry) {
        stored.saved.removeAll { $0.id == entry.id }
        stored.localSaved?.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    /// Keeps a saved manga's details and chapter list current after it's
    /// been refreshed.
    func update(source: String, manga: AidokuRunner.Manga) {
        guard let index = stored.saved.firstIndex(where: { $0.sourceKey == source && $0.manga.key == manga.key }) else { return }
        var copy = manga
        let keys = copy.chapters?.map(\.key)
        copy.chapters = nil
        var changed = false
        if stored.saved[index].manga != copy {
            stored.saved[index].manga = copy
            changed = true
        }
        if let keys, stored.saved[index].chapterKeys != keys {
            stored.saved[index].chapterKeys = keys
            changed = true
        }
        if changed { scheduleSave() }
    }

    // MARK: Names

    /// The name the user gave a title (by library entry id), if any.
    func name(_ id: String) -> String? { stored.names?[id] }

    /// Renames a title; an empty name gives it back its own.
    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = stored.names ?? [:]
        names[id] = trimmed.isEmpty ? nil : trimmed
        stored.names = names
        scheduleSave()
    }

    // MARK: Shelves

    var shelves: [MangaShelf] { stored.shelves ?? [] }

    @discardableResult
    func addShelf(_ name: String) -> MangaShelf? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let shelf = MangaShelf(name: trimmed)
        stored.shelves = shelves + [shelf]
        scheduleSave()
        return shelf
    }

    func renameShelf(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = shelves.firstIndex(where: { $0.id == id }) else { return }
        stored.shelves?[index].name = trimmed
        scheduleSave()
    }

    func deleteShelf(_ id: UUID) {
        stored.shelves?.removeAll { $0.id == id }
        for index in stored.saved.indices { stored.saved[index].shelves?.remove(id) }
        for index in (stored.localSaved ?? []).indices { stored.localSaved?[index].shelves?.remove(id) }
        scheduleSave()
    }

    func moveShelves(from source: IndexSet, to destination: Int) {
        var list = shelves
        list.move(fromOffsets: source, toOffset: destination)
        stored.shelves = list
        scheduleSave()
    }

    func setShelf(_ shelf: UUID, on: Bool, for entryID: String) {
        if let index = stored.saved.firstIndex(where: { $0.id == entryID }) {
            var set = stored.saved[index].shelves ?? []
            if on { set.insert(shelf) } else { set.remove(shelf) }
            stored.saved[index].shelves = set
        } else if let index = stored.localSaved?.firstIndex(where: { $0.id == entryID }) {
            var set = stored.localSaved?[index].shelves ?? []
            if on { set.insert(shelf) } else { set.remove(shelf) }
            stored.localSaved?[index].shelves = set
        }
        scheduleSave()
    }

    // MARK: Reading position

    func page(for unit: String) -> Int { stored.pages[unit] ?? 0 }

    func isFinished(_ unit: String) -> Bool { stored.finished.contains(unit) }

    func setPage(_ page: Int, of count: Int, for unit: String) {
        var changed = false
        if stored.pages[unit] != page {
            stored.pages[unit] = page
            changed = true
        }
        if count > 0, stored.pageCounts?[unit] != count {
            var counts = stored.pageCounts ?? [:]
            counts[unit] = count
            stored.pageCounts = counts
            changed = true
        }
        if count > 0, page >= count - 1, !stored.finished.contains(unit) {
            stored.finished.insert(unit)
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// Marks chapters or volumes read (to the end) or unread (from the start).
    func setRead(_ units: [String], read: Bool) {
        guard !units.isEmpty else { return }
        for unit in units {
            if read {
                stored.finished.insert(unit)
                if let count = stored.pageCounts?[unit], count > 0 { stored.pages[unit] = count - 1 }
            } else {
                stored.finished.remove(unit)
                stored.pages[unit] = nil
            }
        }
        scheduleSave()
    }

    /// The title being read now, so the library can put it first.
    func noteRead(_ entryID: String) {
        var map = stored.lastRead ?? [:]
        if let last = map[entryID], Date().timeIntervalSince(last) < 60 { return }
        map[entryID] = Date()
        stored.lastRead = map
        scheduleSave()
    }

    func lastChapter(for mangaID: String) -> String? { stored.lastChapter[mangaID] }

    func setLastChapter(_ chapter: String, for mangaID: String) {
        guard stored.lastChapter[mangaID] != chapter else { return }
        stored.lastChapter[mangaID] = chapter
        scheduleSave()
    }

    /// How far into one chapter or volume, 0…1.
    func fraction(of unit: String) -> Double {
        if stored.finished.contains(unit) { return 1 }
        let page = stored.pages[unit] ?? 0
        guard page > 0 else { return 0 }
        if let count = stored.pageCounts?[unit], count > 1 {
            return min(Double(page + 1) / Double(count), 1)
        }
        return 0.05
    }

    /// How much of a title has been read, 0…1, or nil when its chapters
    /// aren't known yet.
    func progress(of entry: LibraryEntry, localSeries: LocalSeries?) -> Double? {
        let units: [String]
        switch entry.kind {
        case .source(let key, let manga):
            guard let keys = stored.saved.first(where: { $0.id == entry.id })?.chapterKeys, !keys.isEmpty else { return nil }
            units = keys.map { Self.chapterID(source: key, manga: manga.key, chapter: $0) }
        case .local:
            guard let localSeries, !localSeries.volumes.isEmpty else { return nil }
            units = localSeries.volumes.map(\.unitID)
        }
        return units.reduce(0) { $0 + fraction(of: $1) } / Double(units.count)
    }

    // MARK: Saving

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
