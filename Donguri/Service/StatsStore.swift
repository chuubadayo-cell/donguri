//
//  StatsStore.swift
//  Donguri
//
//  学習の記録: per day, the words looked up, the cards added to Anki, the
//  time spent watching videos and which videos. Counted where each happens
//  (a popup with results, Anki confirming a card, the player while it
//  plays) and kept in UserDefaults.
//

import Foundation
import SwiftUI

@Observable
final class StatsStore {
    static let shared = StatsStore()

    nonisolated struct Day: Codable, Equatable, Sendable {
        var lookups = 0
        var cards = 0
        var watchSeconds: Double = 0
        /// Videos watched for at least `videoThreshold` that day.
        var videos: [String] = []
    }

    nonisolated struct CardRecord: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var word: String
        var date: Date
    }

    enum Metric: String, CaseIterable, Identifiable {
        case watchTime, videos, lookups, cards
        var id: String { rawValue }

        var title: String {
            switch self {
            case .watchTime: String(localized: "視聴時間")
            case .videos: String(localized: "見た動画")
            case .lookups: String(localized: "調べた語")
            case .cards: String(localized: "Ankiに追加")
            }
        }

        var systemImage: String {
            switch self {
            case .watchTime: "clock"
            case .videos: "play.rectangle"
            case .lookups: "character.book.closed.ja"
            case .cards: "plus.rectangle.on.rectangle"
            }
        }

        var color: Color {
            switch self {
            case .watchTime: .red
            case .videos: .orange
            case .lookups: .blue
            case .cards: .green
            }
        }

        func value(_ day: Day) -> Double {
            switch self {
            case .watchTime: day.watchSeconds / 60
            case .videos: Double(day.videos.count)
            case .lookups: Double(day.lookups)
            case .cards: Double(day.cards)
            }
        }

        /// A value of this metric, written out.
        func format(_ value: Double) -> String {
            switch self {
            case .watchTime: StatsStore.formatMinutes(value)
            default: Int(value.rounded()).formatted()
            }
        }
    }

    /// Watching a video this long in a day counts it as watched.
    static let videoThreshold: TimeInterval = 30

    private static let key = "iroha.stats.v1"
    private static let maxRecentCards = 300

    private(set) var days: [String: Day] = [:]
    private(set) var recentCards: [CardRecord] = []

    /// Seconds watched per video today, to tell when one counts.
    @ObservationIgnored private var watchedToday: [String: Double] = [:]
    @ObservationIgnored private var watchedTodayKey = ""
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    private nonisolated struct Saved: Codable {
        var days: [String: Day]
        var recentCards: [CardRecord]
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            days = saved.days
            recentCards = saved.recentCards
        }
    }

    // MARK: Counting

    func noteLookup() {
        days[Self.key(for: .now), default: Day()].lookups += 1
        scheduleSave()
    }

    func noteCard(word: String) {
        days[Self.key(for: .now), default: Day()].cards += 1
        recentCards.insert(CardRecord(word: word, date: .now), at: 0)
        if recentCards.count > Self.maxRecentCards { recentCards.removeLast(recentCards.count - Self.maxRecentCards) }
        scheduleSave()
    }

    func addWatch(seconds: Double, videoID: String) {
        guard seconds > 0 else { return }
        let today = Self.key(for: .now)
        if watchedTodayKey != today {
            watchedTodayKey = today
            watchedToday = [:]
        }
        days[today, default: Day()].watchSeconds += seconds
        let total = (watchedToday[videoID] ?? 0) + seconds
        watchedToday[videoID] = total
        if total >= Self.videoThreshold, days[today]?.videos.contains(videoID) == false {
            days[today]?.videos.append(videoID)
        }
        scheduleSave()
    }

    func reset() {
        days = [:]
        recentCards = []
        watchedToday = [:]
        save()
    }

    // MARK: Reading

    func day(_ date: Date) -> Day {
        days[Self.key(for: date)] ?? Day()
    }

    /// The metric summed over the `count` days ending today.
    func total(_ metric: Metric, lastDays count: Int) -> Double {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<count).reduce(0) { sum, offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return sum }
            return sum + metric.value(day(date))
        }
    }

    func allTime(_ metric: Metric) -> Double {
        days.values.reduce(0) { $0 + metric.value($1) }
    }

    /// Days in a row, up to today (or yesterday, if today has nothing yet),
    /// with anything done.
    var streak: Int {
        let calendar = Calendar.current
        var date = calendar.startOfDay(for: .now)
        if !isActive(day(date)) { date = calendar.date(byAdding: .day, value: -1, to: date) ?? date }
        var count = 0
        while isActive(day(date)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }

    private func isActive(_ day: Day) -> Bool {
        day.lookups > 0 || day.cards > 0 || day.watchSeconds >= 60
    }

    // MARK: Helpers

    static func key(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func formatMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total >= 60 {
            return String(localized: "\(total / 60)時間\(total % 60)分")
        }
        return String(localized: "\(total)分")
    }

    // MARK: Saving

    /// Watch time arrives every few seconds; writes are gathered.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func flush() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(days: days, recentCards: recentCards)) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
