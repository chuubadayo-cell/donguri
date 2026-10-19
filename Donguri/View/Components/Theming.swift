//
//  Theming.swift
//  Donguri
//
//  Applies the sepia themes' palette to screens, rows and bars. With the
//  system, light and dark themes these are no-ops, so iOS's own colours are
//  left alone.
//

import SwiftUI
import UIKit

extension View {
    /// Page background and navigation bar for a list screen.
    func themedScreen() -> some View {
        modifier(ThemedScreen())
    }

    /// Card colour for rows of an inset-grouped list.
    func themedRow() -> some View {
        modifier(ThemedRow())
    }
}

private struct ThemedScreen: ViewModifier {
    @State private var appearance = AppearanceSettings.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        if let palette = appearance.palette {
            content
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: palette.background).ignoresSafeArea())
                .toolbarBackground(Color(uiColor: palette.bar), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}

private struct ThemedRow: ViewModifier {
    @State private var appearance = AppearanceSettings.shared

    func body(content: Content) -> some View {
        content.listRowBackground(appearance.palette.map { Color(uiColor: $0.bar) })
    }
}

/// The ID chip colour, as Chance computes it for imageboard poster IDs: a
/// stable colour hashed from the ID, with black or white text, whichever
/// reads better. The same poster gets the same colour all day.
enum IDColor {
    static func colors(for id: String) -> (background: Color, foreground: Color) {
        let units = Array(id.utf16)
        guard !units.isEmpty else { return (.secondary.opacity(0.15), .primary) }
        var hash: Int64 = 0
        // Short IDs are wrapped so they still use the whole colour range.
        for i in 0..<max(7, units.count) {
            hash = (hash &<< 5) &- hash &+ Int64(units[i % units.count])
        }
        let r = Double((hash >> 24) & 0xFF) / 255
        let g = Double((hash >> 16) & 0xFF) / 255
        let b = Double((hash >> 8) & 0xFF) / 255
        let luminance = r * 0.299 + g * 0.587 + b * 0.114
        return (Color(red: r, green: g, blue: b), luminance > 0.49 ? .black : .white)
    }
}

/// Dates in 5ch's `2026/10/18(日) 21:04:33.12` format, which are Japan time.
enum PostDate {
    private static var cache: [String: Date] = [:]

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }()

    static func date(from string: String) -> Date? {
        if let cached = cache[string] { return cached }
        guard let match = string.firstMatch(of: #/(\d{4})\/(\d{1,2})\/(\d{1,2})[^\d]*?(\d{1,2}):(\d{2})(?::(\d{2}))?/#) else {
            return nil
        }
        var components = DateComponents()
        components.year = Int(match.1)
        components.month = Int(match.2)
        components.day = Int(match.3)
        components.hour = Int(match.4)
        components.minute = Int(match.5)
        components.second = match.6.flatMap { Int($0) } ?? 0
        let date = calendar.date(from: components)
        if cache.count > 5000 { cache.removeAll() }
        cache[string] = date
        return date
    }

    /// "21:04" today, "10/18 21:04" this year, otherwise the full date.
    static func shortLabel(for date: Date, now: Date = .now) -> String {
        let local = Calendar.current
        if local.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if local.component(.year, from: date) == local.component(.year, from: now) {
            return date.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
        }
        return date.formatted(date: .numeric, time: .shortened)
    }

    static func relativeLabel(for date: Date, now: Date = .now) -> String {
        date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}
