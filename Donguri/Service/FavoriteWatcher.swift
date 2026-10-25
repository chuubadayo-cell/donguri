//
//  FavoriteWatcher.swift
//  Donguri
//
//  Notifications for favorite threads: new replies, and a 次スレ appearing
//  once a favorite fills up. Runs as a background app refresh, so iOS
//  decides exactly when (usually every so often while the phone is in use,
//  less when it's idle or in Low Power Mode).
//

import Foundation
import BackgroundTasks
import UserNotifications

final class FavoriteWatcher {
    static let shared = FavoriteWatcher()

    /// Also listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let taskIdentifier = "iroha.favorites.refresh"

    private static let notifiedCountsKey = "donguri.notifiedCounts"
    private static let notifiedNextKey = "donguri.notifiedNextThreads"
    /// More threads than this with news become one summary notification.
    private static let maxSeparateNotifications = 4

    // MARK: Permission

    /// Asks once; afterwards returns what the user chose.
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status: UNAuthorizationStatus = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    // MARK: Scheduling

    func schedule() {
        guard BehaviorSettings.shared.anyNotifications else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Fails in the simulator, and when Background App Refresh is off.
            print("FavoriteWatcher schedule error: \(error)")
        }
    }

    // MARK: Checking

    /// The background refresh: update counts, then notify.
    func runBackgroundRefresh() async {
        defer { schedule() }
        guard BehaviorSettings.shared.anyNotifications else { return }
        await check()
    }

    func check() async {
        let favorites = FavoritesStore.shared
        await favorites.refreshThreadCounts()

        var pending: [UNMutableNotificationContent] = []
        if BehaviorSettings.shared.notifyNewPosts {
            pending += newPostNotifications()
        }
        if BehaviorSettings.shared.notifyNextThread {
            pending += await nextThreadNotifications()
        }
        await deliver(pending)
    }

    /// Favorites whose reply count has grown by the threshold since the
    /// user read them or was last told about them.
    private func newPostNotifications() -> [UNMutableNotificationContent] {
        let favorites = FavoritesStore.shared
        let threshold = max(BehaviorSettings.shared.notifyThreshold, 1)
        var notified = UserDefaults.standard.dictionary(forKey: Self.notifiedCountsKey) as? [String: Int] ?? [:]
        var news: [(thread: FavoriteThread, count: Int)] = []

        for thread in favorites.threads where !thread.isArchived {
            let read = ReadStateStore.shared.state(for: thread.id)?.lastReadCount ?? 0
            guard let last = notified[thread.id] else {
                // First time seen: start counting from here.
                notified[thread.id] = max(thread.responseCount, read)
                continue
            }
            let baseline = max(last, read)
            let newCount = thread.responseCount - baseline
            if newCount >= threshold {
                news.append((thread, newCount))
                notified[thread.id] = thread.responseCount
            }
        }
        // Forget threads that are no longer favorites.
        let keys = Set(favorites.threads.map(\.id))
        notified = notified.filter { keys.contains($0.key) }
        UserDefaults.standard.set(notified, forKey: Self.notifiedCountsKey)

        guard !news.isEmpty else { return [] }
        if news.count > Self.maxSeparateNotifications {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "お気に入りに新着があります")
            content.body = news.prefix(5)
                .map { "\($0.thread.title)（+\($0.count)）" }
                .joined(separator: "\n")
            content.sound = .default
            content.threadIdentifier = "favorites"
            return [content]
        }
        return news.map { item in
            let content = UNMutableNotificationContent()
            content.title = item.thread.title
            content.subtitle = item.thread.boardName
            content.body = String(localized: "新着レス \(item.count)件")
            content.sound = .default
            content.threadIdentifier = item.thread.id
            content.userInfo = Self.userInfo(for: item.thread.link)
            return content
        }
    }

    /// Full or archived favorites whose continuation has appeared.
    private func nextThreadNotifications() async -> [UNMutableNotificationContent] {
        let favorites = FavoritesStore.shared
        var notified = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedNextKey) ?? [])
        let finished = favorites.threads.filter { ($0.isArchived || $0.responseCount >= 1000) && !notified.contains($0.id) }
        guard !finished.isEmpty else { return [] }

        var listings: [String: [Thread]] = [:]
        var contents: [UNMutableNotificationContent] = []
        for thread in finished {
            if listings[thread.boardURL] == nil {
                listings[thread.boardURL] = (try? await ThreadService().fetchThreads(boardURL: thread.boardURL)) ?? []
            }
            guard let next = NextThreadFinder.find(after: thread.threadId,
                                                   title: thread.title,
                                                   in: listings[thread.boardURL] ?? []) else { continue }
            notified.insert(thread.id)
            let link = ThreadLink(boardURL: thread.boardURL, threadId: next.id, title: next.title,
                                  boardName: thread.boardName, responseCount: next.responseCount)
            if BehaviorSettings.shared.autoFavoriteNextThread,
               !favorites.isFavorite(boardURL: thread.boardURL, threadId: next.id) {
                favorites.toggle(boardURL: thread.boardURL, boardName: thread.boardName,
                                 threadId: next.id, title: next.title ?? thread.title,
                                 responseCount: next.responseCount)
            }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "次スレが立ちました")
            content.subtitle = thread.boardName
            content.body = next.title ?? thread.title
            content.sound = .default
            content.threadIdentifier = "next|" + thread.id
            content.userInfo = Self.userInfo(for: link)
            contents.append(content)
        }
        UserDefaults.standard.set(Array(notified), forKey: Self.notifiedNextKey)
        return contents
    }

    private func deliver(_ contents: [UNMutableNotificationContent]) async {
        let center = UNUserNotificationCenter.current()
        for content in contents {
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    /// A notification to check that notifications work.
    func sendTest() async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "通知のテスト")
        content.body = String(localized: "お気に入りスレに新着があると、このように通知されます。")
        content.sound = .default
        await deliver([content])
    }

    private static func userInfo(for link: ThreadLink) -> [String: Any] {
        var info: [String: Any] = ["boardURL": link.boardURL, "threadId": link.threadId]
        if let title = link.title { info["title"] = title }
        if let boardName = link.boardName { info["boardName"] = boardName }
        return info
    }
}

/// Shows notifications while the app is open, and opens the thread when
/// one is tapped. Not main-actor isolated: UserNotifications calls these
/// on a background queue.
nonisolated final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (Int) -> Void) {
        // With C++ interop on (hoshidicts needs it), the block's NS_OPTIONS
        // parameter is imported as its raw integer rather than as
        // UNNotificationPresentationOptions, so the witness has to match.
        let options: UNNotificationPresentationOptions = [.banner, .list, .sound]
        completionHandler(Int(options.rawValue))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let boardURL = info["boardURL"] as? String,
              let threadId = info["threadId"] as? Int else { return }
        let title = info["title"] as? String
        let boardName = info["boardName"] as? String
        await MainActor.run {
            AppNavigator.shared.showThread(ThreadLink(boardURL: boardURL, threadId: threadId,
                                                      title: title, boardName: boardName))
        }
    }
}
