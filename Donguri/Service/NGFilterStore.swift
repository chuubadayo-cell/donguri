//
//  NGFilterStore.swift
//  Donguri
//
//  Created by John Connery on 9/3/26.
//

import Foundation
import SwiftUI

/// Stores the user's NG (あぼーん) rules and decides which posts they hide.
///
/// Filtered posts are never removed from the thread's post array — `>>N` links
/// and `Post.replies` are both plain indices into it, so dropping elements would
/// silently misnumber every later reply. `ThreadView` renders a placeholder row
/// in place of a hidden post instead.
@Observable
final class NGFilterStore {
    static let shared = NGFilterStore()

    private static let defaultsKey = "donguri.ngRules"
    private static let hiddenThreadsKey = "donguri.hiddenThreads"
    /// Threads die within weeks; old entries are dropped past this many.
    private static let maxHiddenThreads = 2000

    private(set) var rules: [NGRule]
    /// Newest first.
    private(set) var hiddenThreads: [HiddenThread]
    private var hiddenKeys: Set<String>

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([NGRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
        if let data = UserDefaults.standard.data(forKey: Self.hiddenThreadsKey),
           let decoded = try? JSONDecoder().decode([HiddenThread].self, from: data) {
            hiddenThreads = decoded
        } else {
            hiddenThreads = []
        }
        hiddenKeys = Set(hiddenThreads.map(\.id))
    }

    // MARK: Threads

    var threadTitleRules: [NGRule] { rules.filter { $0.kind == .threadTitle } }

    func isHidden(boardURL: String, threadId: Int) -> Bool {
        hiddenKeys.contains(ReadStateStore.key(boardURL: boardURL, threadId: threadId))
    }

    /// Hidden one by one, or by an NGスレタイ rule.
    func hides(thread: Thread, boardURL: String) -> Bool {
        if isHidden(boardURL: boardURL, threadId: thread.id) { return true }
        return hidesTitle(thread.title)
    }

    func hidesTitle(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return rules.contains { $0.kind == .threadTitle && title.localizedCaseInsensitiveContains($0.pattern) }
    }

    func hide(boardURL: String, threadId: Int, title: String) {
        let entry = HiddenThread(boardURL: boardURL, threadId: threadId, title: title)
        guard !hiddenKeys.contains(entry.id) else { return }
        hiddenThreads.insert(entry, at: 0)
        hiddenKeys.insert(entry.id)
        if hiddenThreads.count > Self.maxHiddenThreads {
            for dropped in hiddenThreads.suffix(hiddenThreads.count - Self.maxHiddenThreads) {
                hiddenKeys.remove(dropped.id)
            }
            hiddenThreads.removeLast(hiddenThreads.count - Self.maxHiddenThreads)
        }
        persistHidden()
    }

    func unhide(boardURL: String, threadId: Int) {
        let key = ReadStateStore.key(boardURL: boardURL, threadId: threadId)
        hiddenThreads.removeAll { $0.id == key }
        hiddenKeys.remove(key)
        persistHidden()
    }

    func unhideThreads(atOffsets offsets: IndexSet) {
        hiddenThreads.remove(atOffsets: offsets)
        hiddenKeys = Set(hiddenThreads.map(\.id))
        persistHidden()
    }

    func unhideAll() {
        hiddenThreads.removeAll()
        hiddenKeys.removeAll()
        persistHidden()
    }

    private func persistHidden() {
        guard let data = try? JSONEncoder().encode(hiddenThreads) else { return }
        UserDefaults.standard.set(data, forKey: Self.hiddenThreadsKey)
    }

    // MARK: Rules

    func add(kind: NGRule.Kind, pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !rules.contains(where: { $0.kind == kind && $0.pattern == trimmed }) else { return }
        rules.append(NGRule(kind: kind, pattern: trimmed))
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        persist()
    }

    func remove(kind: NGRule.Kind, pattern: String) {
        rules.removeAll { $0.kind == kind && $0.pattern == pattern }
        persist()
    }

    func contains(kind: NGRule.Kind, pattern: String) -> Bool {
        rules.contains { $0.kind == kind && $0.pattern == pattern }
    }

    /// Case-insensitive substring match, which is what 5ch clients do by default.
    func hides(_ post: Post) -> Bool {
        guard !rules.isEmpty else { return false }

        for rule in rules {
            switch rule.kind {
            case .word:
                if post.text.localizedCaseInsensitiveContains(rule.pattern) { return true }
            case .id:
                if let id = post.id, id.localizedCaseInsensitiveContains(rule.pattern) { return true }
            case .name:
                if post.name.localizedCaseInsensitiveContains(rule.pattern) { return true }
                if let trip = post.trip, trip.localizedCaseInsensitiveContains(rule.pattern) { return true }
            case .threadTitle:
                continue
            }
        }
        return false
    }

    /// Indices of every post in `posts` hidden by the current rules.
    func hiddenIndices(in posts: [Post]) -> Set<Int> {
        guard !rules.isEmpty else { return [] }
        var hidden = Set<Int>()
        for (index, post) in posts.enumerated() where hides(post) {
            hidden.insert(index)
        }
        return hidden
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
