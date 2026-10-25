//
//  BookmarkStore.swift
//  Donguri
//
//  The browser's bookmarks: saved from the address bar's star, shown on
//  the start page and in their own list. Kept in UserDefaults, in the
//  user's order.
//

import Foundation
import SwiftUI

nonisolated struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var url: String
    var added = Date.now

    var host: String {
        let host = URL(string: url)?.host ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

@Observable
final class BookmarkStore {
    static let shared = BookmarkStore()

    private static let key = "iroha.browser.bookmarks"

    private(set) var bookmarks: [Bookmark]

    private init() {
        bookmarks = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
    }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        let key = Self.normalized(url.absoluteString)
        return bookmarks.contains { Self.normalized($0.url) == key }
    }

    /// Adds the page, or removes it if it's already there.
    func toggle(url: URL, title: String) {
        let key = Self.normalized(url.absoluteString)
        if let index = bookmarks.firstIndex(where: { Self.normalized($0.url) == key }) {
            bookmarks.remove(at: index)
        } else {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            bookmarks.insert(Bookmark(title: name.isEmpty ? (url.host ?? url.absoluteString) : name,
                                      url: url.absoluteString), at: 0)
        }
        save()
    }

    func rename(_ bookmark: Bookmark, to title: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        bookmarks[index].title = name
        save()
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// The same page with or without a trailing slash or fragment.
    private static func normalized(_ url: String) -> String {
        var value = url
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        while value.hasSuffix("/") { value.removeLast() }
        return value.lowercased()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
