//
//  Thread+Momentum.swift
//  Donguri
//
//  勢い (momentum): how fast a thread is moving, in replies per day. 5ch
//  readers sort by this to find what's busy, and for reading practice it's
//  just as useful the other way round, to find threads slow enough to read.
//

import Foundation

extension Thread {
    /// Replies per day since the thread was created, or nil for threads whose
    /// key isn't a real creation time.
    ///
    /// A thread's key in subject.txt (its `id` here) is the Unix time it was
    /// created, so no extra request is needed. Pinned and ad threads use keys
    /// far in the future; those get nil and sort last. Elapsed time is floored
    /// at one hour so a thread created a minute ago with two replies doesn't
    /// show a meaningless 勢い of 2,880.
    func momentum(now: Date = .now) -> Double? {
        let elapsed = now.timeIntervalSince1970 - TimeInterval(id)
        guard elapsed > -3600, responseCount >= 0 else { return nil }
        let days = max(elapsed, 3600) / 86_400
        return Double(responseCount) / days
    }

    var isFull: Bool { responseCount >= 1000 }
}

enum ThreadSortOrder: String, CaseIterable, Identifiable {
    /// The board's own order (most recently bumped first), as 5ch serves it.
    case board
    case momentum
    case slowest
    case newest
    case replies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: String(localized: "板の順番")
        case .momentum: String(localized: "勢い順")
        case .slowest: String(localized: "ゆっくり順")
        case .newest: String(localized: "新しい順")
        case .replies: String(localized: "レス数順")
        }
    }

    var systemImage: String {
        switch self {
        case .board: "list.bullet"
        case .momentum: "flame"
        case .slowest: "tortoise"
        case .newest: "sparkles"
        case .replies: "message"
        }
    }

    func sorted(_ threads: [Thread], now: Date = .now) -> [Thread] {
        switch self {
        case .board:
            return threads
        case .momentum:
            return threads.sorted { ($0.momentum(now: now) ?? -1) > ($1.momentum(now: now) ?? -1) }
        case .slowest:
            // Full threads are finished, not slow, so they go to the bottom
            // along with pinned threads.
            return threads.sorted { a, b in
                let ma = a.isFull ? nil : a.momentum(now: now)
                let mb = b.isFull ? nil : b.momentum(now: now)
                switch (ma, mb) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                default: return false
                }
            }
        case .newest:
            return threads.sorted { $0.id > $1.id }
        case .replies:
            return threads.sorted { $0.responseCount > $1.responseCount }
        }
    }
}

extension Double {
    /// 勢い as 5ch readers show it: whole numbers, with tiny values kept
    /// visible rather than rounding to zero.
    var momentumLabel: String {
        if self < 1 { return String(format: "%.1f", self) }
        return Int(self.rounded()).formatted()
    }
}
