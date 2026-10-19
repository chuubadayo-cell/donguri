//
//  BehaviorSettings.swift
//  Donguri
//
//  操作: how the app behaves, as opposed to how it looks (AppearanceSettings).
//  Gestures, haptics, auto-refresh and notifications. Backed by UserDefaults.
//

import SwiftUI
import UIKit

@Observable
final class BehaviorSettings {
    static let shared = BehaviorSettings()

    private static let prefix = "donguri.behavior."

    /// Swipe right anywhere on the screen to go back, not just from the edge.
    var fullSwipeBack: Bool { didSet { save(fullSwipeBack, "fullSwipeBack"); FullSwipeBackManager.shared.settingDidChange() } }
    var haptics: Bool { didSet { save(haptics, "haptics") } }

    // MARK: Auto-refresh

    /// Seconds between refreshes when auto-refresh is turned on in a thread.
    var autoRefreshInterval: Int { didSet { save(autoRefreshInterval, "autoRefreshInterval") } }
    /// 実況 boards (directory `live…`) start with auto-refresh on.
    var autoRefreshLiveBoards: Bool { didSet { save(autoRefreshLiveBoards, "autoRefreshLiveBoards") } }
    /// When new posts arrive and you're at the bottom, scroll them in.
    var followNewPosts: Bool { didSet { save(followNewPosts, "followNewPosts") } }

    // MARK: Notifications

    var notifyNewPosts: Bool { didSet { save(notifyNewPosts, "notifyNewPosts") } }
    /// Only notify once a favorite has at least this many new posts.
    var notifyThreshold: Int { didSet { save(notifyThreshold, "notifyThreshold") } }
    var notifyNextThread: Bool { didSet { save(notifyNextThread, "notifyNextThread") } }
    /// Add a found 次スレ to favorites automatically.
    var autoFavoriteNextThread: Bool { didSet { save(autoFavoriteNextThread, "autoFavoriteNextThread") } }

    static let refreshIntervals = [5, 10, 20, 30, 60]
    static let notifyThresholds = [1, 5, 10, 30, 100]

    private init() {
        let d = UserDefaults.standard
        let p = Self.prefix
        fullSwipeBack = d.object(forKey: p + "fullSwipeBack") as? Bool ?? true
        haptics = d.object(forKey: p + "haptics") as? Bool ?? true
        autoRefreshInterval = d.object(forKey: p + "autoRefreshInterval") as? Int ?? 10
        autoRefreshLiveBoards = d.object(forKey: p + "autoRefreshLiveBoards") as? Bool ?? true
        followNewPosts = d.object(forKey: p + "followNewPosts") as? Bool ?? true
        notifyNewPosts = d.object(forKey: p + "notifyNewPosts") as? Bool ?? false
        notifyThreshold = d.object(forKey: p + "notifyThreshold") as? Int ?? 1
        notifyNextThread = d.object(forKey: p + "notifyNextThread") as? Bool ?? false
        autoFavoriteNextThread = d.object(forKey: p + "autoFavoriteNextThread") as? Bool ?? true
    }

    var anyNotifications: Bool { notifyNewPosts || notifyNextThread }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: Self.prefix + key)
    }
}

/// Small taps of feedback for things that happen without looking: a
/// favorite toggled, a jump landing, new posts arriving.
enum Haptics {
    enum Kind {
        case light, medium, selection, success, warning
    }

    static func play(_ kind: Kind) {
        guard BehaviorSettings.shared.haptics else { return }
        switch kind {
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
