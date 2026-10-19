//
//  HistoryStore.swift
//  Donguri
//
//  Browsing history (閲覧履歴): every thread the user opens, newest first.
//  Backed by `UserDefaults` and capped so it can't grow forever.
//

import Foundation
import SwiftUI

@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private static let defaultsKey = "donguri.history"
    private static let maxEntries = 300

    private(set) var entries: [HistoryEntry]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// Moves the thread to the top of the history, adding it if it's new.
    func record(boardURL: String, boardName: String?, threadId: Int, title: String?, responseCount: Int) {
        let existing = entries.first { $0.boardURL == boardURL && $0.threadId == threadId }
        entries.removeAll { $0.boardURL == boardURL && $0.threadId == threadId }

        let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 }
            ?? existing?.title
            ?? String(localized: "無題")

        entries.insert(HistoryEntry(boardURL: boardURL,
                                    boardName: boardName ?? existing?.boardName ?? knownBoardName(for: boardURL),
                                    threadId: threadId,
                                    title: resolvedTitle,
                                    responseCount: max(responseCount, existing?.responseCount ?? 0),
                                    lastViewed: .now),
                       at: 0)

        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        persist()
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    /// The board's real name if any part of the library has seen it, so a
    /// thread opened from a link still gets a readable board name.
    func knownBoardName(for boardURL: String) -> String {
        if let board = FavoritesStore.shared.boards.first(where: { $0.url == boardURL }) {
            return board.boardName
        }
        let fallback = BoardNames.fallback(for: boardURL)
        if let entry = entries.first(where: { $0.boardURL == boardURL && $0.boardName != fallback }) {
            return entry.boardName
        }
        return fallback
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
