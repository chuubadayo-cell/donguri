//
//  ThreadMemoryCache.swift
//  Donguri
//
//  The last few threads' parsed posts, kept in memory so going back into a
//  thread (from the board list, history or favorites) shows it immediately
//  while the refresh runs in the background.
//

import Foundation
import UIKit

final class ThreadMemoryCache {
    static let shared = ThreadMemoryCache()

    private static let capacity = 8

    private var posts: [String: [Post]] = [:]
    /// Most recently used last.
    private var order: [String] = []

    private init() {
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                   object: nil,
                                                   queue: .main) { _ in
            MainActor.assumeIsolated {
                ThreadMemoryCache.shared.removeAll()
            }
        }
    }

    func posts(for key: String) -> [Post]? {
        guard let cached = posts[key] else { return nil }
        touch(key)
        return cached
    }

    func store(_ newPosts: [Post], for key: String) {
        posts[key] = newPosts
        touch(key)
        while order.count > Self.capacity {
            let evicted = order.removeFirst()
            posts[evicted] = nil
        }
    }

    func removeAll() {
        posts.removeAll()
        order.removeAll()
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
