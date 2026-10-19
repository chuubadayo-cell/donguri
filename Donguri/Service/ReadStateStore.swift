//
//  ReadStateStore.swift
//  Donguri
//
//  Created by John Connery on 8/17/26.
//

import Foundation

/// Tracks how far the user has read into each thread, so the board list can
/// show an unread count and reopening a thread can resume near where the
/// user left off. Backed by `UserDefaults`, cached in memory.
final class ReadStateStore {
    static let shared = ReadStateStore()

    private static let defaultsKey = "donguri.readState"

    /// Read positions for threads not opened in this long are forgotten, so
    /// the store (rewritten in full on every save) doesn't grow forever.
    /// Favorite threads are always kept.
    private static let retention: TimeInterval = 180 * 24 * 60 * 60
    private static let maxEntries = 3000

    private var cache: [String: ReadState]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: ReadState].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
        prune()
    }

    private func prune() {
        let now = Date.now
        let favorites = Set(FavoritesStore.shared.threads.map(\.id))
        var changed = false

        for (key, state) in cache {
            guard let visited = state.lastVisited else {
                // From an older build: start its clock now.
                cache[key]?.lastVisited = now
                changed = true
                continue
            }
            if now.timeIntervalSince(visited) > Self.retention, !favorites.contains(key) {
                cache[key] = nil
                changed = true
            }
        }

        if cache.count > Self.maxEntries {
            let oldestFirst = cache
                .filter { !favorites.contains($0.key) }
                .sorted { ($0.value.lastVisited ?? .distantPast) < ($1.value.lastVisited ?? .distantPast) }
            for (key, _) in oldestFirst.prefix(cache.count - Self.maxEntries) {
                cache[key] = nil
            }
            changed = true
        }

        if changed { persist() }
    }

    static func key(boardURL: String, threadId: Int) -> String {
        "\(boardURL)|\(threadId)"
    }

    func state(for key: String) -> ReadState? {
        cache[key]
    }

    func update(key: String, postCount: Int, readIndex: Int) {
        let existing = cache[key]
        cache[key] = ReadState(
            lastReadCount: max(existing?.lastReadCount ?? 0, postCount),
            lastReadIndex: max(existing?.lastReadIndex ?? 0, readIndex),
            lastVisited: .now
        )
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
