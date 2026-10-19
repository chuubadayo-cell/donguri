//
//  FavoritesStore.swift
//  Donguri
//
//  Favorite boards and threads (お気に入り), shown at the top of the board
//  menu. Backed by `UserDefaults`, like `ReadStateStore` and `NGFilterStore`.
//

import Foundation
import SwiftUI

@Observable
final class FavoritesStore {
    static let shared = FavoritesStore()

    private static let boardsKey = "donguri.favoriteBoards"
    private static let threadsKey = "donguri.favoriteThreads"

    private(set) var boards: [FavoriteBoard]
    private(set) var threads: [FavoriteThread]

    /// Bumped whenever a read position changes. `ReadStateStore` isn't
    /// observable, so views that show unread counts read this to know when to
    /// redraw after the user comes back from a thread.
    private(set) var readRevision = 0

    /// True while `refreshThreadCounts` is fetching board listings.
    private(set) var isRefreshing = false

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.boardsKey),
           let decoded = try? JSONDecoder().decode([FavoriteBoard].self, from: data) {
            boards = decoded
        } else {
            boards = []
        }
        if let data = defaults.data(forKey: Self.threadsKey),
           let decoded = try? JSONDecoder().decode([FavoriteThread].self, from: data) {
            threads = decoded
        } else {
            threads = []
        }
    }

    // MARK: Boards

    func isFavorite(boardURL: String) -> Bool {
        boards.contains { $0.url == boardURL }
    }

    func toggle(board: BBSMenu.CategoryContent) {
        if isFavorite(boardURL: board.url) {
            boards.removeAll { $0.url == board.url }
        } else {
            boards.append(FavoriteBoard(board))
        }
        persistBoards()
    }

    func removeBoards(atOffsets offsets: IndexSet) {
        boards.remove(atOffsets: offsets)
        persistBoards()
    }

    func moveBoards(fromOffsets source: IndexSet, toOffset destination: Int) {
        boards.move(fromOffsets: source, toOffset: destination)
        persistBoards()
    }

    // MARK: Threads

    func isFavorite(boardURL: String, threadId: Int) -> Bool {
        threads.contains { $0.boardURL == boardURL && $0.threadId == threadId }
    }

    func toggle(boardURL: String, boardName: String, threadId: Int, title: String, responseCount: Int) {
        if isFavorite(boardURL: boardURL, threadId: threadId) {
            threads.removeAll { $0.boardURL == boardURL && $0.threadId == threadId }
        } else {
            threads.insert(FavoriteThread(boardURL: boardURL,
                                          boardName: boardName,
                                          threadId: threadId,
                                          title: title,
                                          responseCount: max(responseCount, 0)),
                           at: 0)
        }
        persistThreads()
    }

    func removeThreads(atOffsets offsets: IndexSet) {
        threads.remove(atOffsets: offsets)
        persistThreads()
    }

    func moveThreads(fromOffsets source: IndexSet, toOffset destination: Int) {
        threads.move(fromOffsets: source, toOffset: destination)
        persistThreads()
    }

    /// Called when a favorite thread has been opened, so its count and title
    /// are current without waiting for the next board refresh.
    func noteOpened(boardURL: String, threadId: Int, title: String?, responseCount: Int) {
        guard let i = threads.firstIndex(where: { $0.boardURL == boardURL && $0.threadId == threadId }) else { return }
        var changed = false
        if responseCount > threads[i].responseCount {
            threads[i].responseCount = responseCount
            changed = true
        }
        if let title, !title.isEmpty, title != threads[i].title {
            threads[i].title = title
            changed = true
        }
        if changed { persistThreads() }
    }

    /// Updates favorite threads on one board from a freshly fetched listing.
    /// Lets `BoardView` keep favorites current for free whenever it loads.
    func update(boardURL: String, from listing: [Thread]) {
        guard threads.contains(where: { $0.boardURL == boardURL }) else { return }
        let counts = Dictionary(listing.map { ($0.id, $0.responseCount) },
                                uniquingKeysWith: { first, _ in first })
        var changed = false
        for i in threads.indices where threads[i].boardURL == boardURL {
            if let count = counts[threads[i].threadId] {
                if count != threads[i].responseCount || threads[i].isArchived {
                    threads[i].responseCount = count
                    threads[i].isArchived = false
                    changed = true
                }
            } else if !threads[i].isArchived {
                threads[i].isArchived = true
                changed = true
            }
        }
        if changed { persistThreads() }
    }

    /// Fetches the listing of every board that has a favorite thread, so the
    /// menu can show how many new replies each one has. One request per board.
    func refreshThreadCounts() async {
        guard !isRefreshing else { return }
        let boardURLs = Array(Set(threads.filter { !$0.isArchived }.map(\.boardURL)))
        guard !boardURLs.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let service = ThreadService()
        for boardURL in boardURLs {
            do {
                let listing = try await service.fetchThreads(boardURL: boardURL)
                update(boardURL: boardURL, from: listing)
            } catch {
                // Offline, or the board moved servers. Keep the old counts.
                print("FavoritesStore refresh error for \(boardURL): \(error)")
            }
        }
    }

    // MARK: Unread counts

    func readStateDidChange() {
        readRevision += 1
    }

    /// New replies since the user last read this thread, or nil if none or if
    /// it has never been opened.
    func unreadCount(for thread: FavoriteThread) -> Int? {
        _ = readRevision
        guard let state = ReadStateStore.shared.state(for: thread.id) else { return nil }
        let unread = thread.responseCount - state.lastReadCount
        return unread > 0 ? unread : nil
    }

    // MARK: Persistence

    private func persistBoards() {
        guard let data = try? JSONEncoder().encode(boards) else { return }
        UserDefaults.standard.set(data, forKey: Self.boardsKey)
    }

    private func persistThreads() {
        guard let data = try? JSONEncoder().encode(threads) else { return }
        UserDefaults.standard.set(data, forKey: Self.threadsKey)
    }
}
