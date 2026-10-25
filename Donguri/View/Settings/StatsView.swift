//
//  StatsView.swift
//  Donguri
//
//  学習の記録: today at a glance, a calendar heatmap (as GitHub draws
//  contributions) for any of the four counts, the last two weeks as a
//  chart, totals, and the words most recently added to Anki.
//

import SwiftUI
import Charts

struct StatsView: View {
    @State private var store = StatsStore.shared
    @AppStorage("iroha.stats.metric") private var metricRaw = StatsStore.Metric.watchTime.rawValue
    @State private var selectedDay: Date?
    @State private var confirmReset = false

    private var metric: StatsStore.Metric { StatsStore.Metric(rawValue: metricRaw) ?? .watchTime }

    var body: some View {
        List {
            Section {
                todayGrid
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                HStack {
                    Text("今日")
                    Spacer()
                    if store.streak > 0 {
                        Label("\(store.streak)日連続", systemImage: "flame.fill")
                            .foregroundStyle(.orange)
                            .textCase(nil)
                    }
                }
            }

            Section {
                Picker("項目", selection: $metricRaw) {
                    ForEach(StatsStore.Metric.allCases) { metric in
                        Text(metric.title).tag(metric.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                ActivityHeatmap(store: store, metric: metric, selected: $selectedDay)
                    .frame(height: 132)
                if let selectedDay {
                    dayDetail(selectedDay)
                }
            } header: {
                Text("カレンダー")
            } footer: {
                Text("色が濃い日ほど多く。日付をタップすると、その日の記録が見られます。")
            }

            Section {
                recentChart
                    .frame(height: 170)
                    .padding(.vertical, 6)
            } header: {
                Text("最近の14日間・\(metric.title)")
            }

            Section("合計") {
                ForEach(StatsStore.Metric.allCases) { metric in
                    HStack {
                        Label(metric.title, systemImage: metric.systemImage)
                            .foregroundStyle(metric.color)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(verbatim: metric.format(store.allTime(metric)))
                                .font(.body.monospacedDigit().weight(.semibold))
                            Text("7日間 \(metric.format(store.total(metric, lastDays: 7)))・30日間 \(metric.format(store.total(metric, lastDays: 30)))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                if store.recentCards.isEmpty {
                    Text("まだありません。辞書の＋でカードを作ると、ここに並びます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.recentCards.prefix(30)) { card in
                        HStack {
                            Text(verbatim: card.word)
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(card.date, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("最近Ankiに追加した語")
            }
        }
        .navigationTitle(Text("学習の記録"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("記録をリセット", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("学習の記録をすべて消去しますか？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("すべて消去", role: .destructive) {
                store.reset()
                selectedDay = nil
            }
        }
    }

    // MARK: Today

    private var todayGrid: some View {
        let today = store.day(.now)
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                tile(.watchTime, today)
                tile(.videos, today)
            }
            GridRow {
                tile(.lookups, today)
                tile(.cards, today)
            }
        }
    }

    private func tile(_ metric: StatsStore.Metric, _ day: StatsStore.Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(metric.title, systemImage: metric.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(metric.color)
            Text(verbatim: metric.format(metric.value(day)))
                .font(.title2.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(metric.color.opacity(0.1)))
    }

    // MARK: A day

    private func dayDetail(_ date: Date) -> some View {
        let day = store.day(date)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(date, format: .dateTime.year().month().day().weekday())
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    selectedDay = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 14) {
                ForEach(StatsStore.Metric.allCases) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Image(systemName: metric.systemImage)
                            .foregroundStyle(metric.color)
                        Text(verbatim: metric.format(metric.value(day)))
                            .font(.footnote.monospacedDigit().weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Chart

    private var recentChart: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let points: [(date: Date, value: Double)] = (0..<14).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (date, metric.value(store.day(date)))
        }
        return Chart(points, id: \.date) { point in
            BarMark(x: .value("日", point.date, unit: .day),
                    y: .value(metric.title, point.value))
                .foregroundStyle(metric.color.gradient)
                .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.day(), centered: true)
            }
        }
    }
}

/// Weeks as columns, days as rows, the newest week on the right; each
/// day shaded by the chosen count, relative to the busiest day shown.
private struct ActivityHeatmap: View {
    let store: StatsStore
    let metric: StatsStore.Metric
    @Binding var selected: Date?

    private let cell: CGFloat = 13
    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let labelWidth: CGFloat = 16
            let columns = max(8, Int((geometry.size.width - labelWidth) / (cell + gap)))
            let weeks = Self.weeks(count: columns)
            let values = weeks.flatMap { $0 }.compactMap { $0 }.map { metric.value(store.day($0)) }
            let maximum = max(values.max() ?? 0, 0.0001)
            VStack(alignment: .leading, spacing: 4) {
                // Month labels over the week each month starts in.
                HStack(spacing: gap) {
                    Color.clear.frame(width: labelWidth - gap, height: 12)
                    ForEach(weeks.indices, id: \.self) { index in
                        Text(verbatim: monthLabel(weeks, index))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: cell, height: 12, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: gap) {
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(verbatim: weekdayLabel(row))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: labelWidth - gap, height: cell)
                        }
                    }
                    ForEach(weeks.indices, id: \.self) { column in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                if let date = weeks[column][row] {
                                    square(date, maximum: maximum)
                                } else {
                                    Color.clear.frame(width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
                legend
            }
        }
    }

    private func square(_ date: Date, maximum: Double) -> some View {
        let value = metric.value(store.day(date))
        let isSelected = selected.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color(value, maximum: maximum))
            .frame(width: cell, height: cell)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Color.primary, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.play(.selection)
                withAnimation(.snappy) { selected = isSelected ? nil : date }
            }
            .accessibilityLabel(Text("\(date.formatted(date: .abbreviated, time: .omitted)) \(metric.format(value))"))
    }

    /// Empty, then four shades.
    private func color(_ value: Double, maximum: Double) -> Color {
        guard value > 0 else { return Color.secondary.opacity(0.13) }
        let level = min(4, max(1, Int((value / maximum * 4).rounded(.up))))
        return metric.color.opacity(0.25 + 0.75 * Double(level) / 4)
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Spacer()
            Text("少")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(level == 0 ? Color.secondary.opacity(0.13) : metric.color.opacity(0.25 + 0.75 * Double(level) / 4))
                    .frame(width: 9, height: 9)
            }
            Text("多")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    private func monthLabel(_ weeks: [[Date?]], _ index: Int) -> String {
        guard let first = weeks[index].compactMap({ $0 }).first else { return "" }
        let calendar = Calendar.current
        // The column where the month's first day falls.
        guard weeks[index].compactMap({ $0 }).contains(where: { calendar.component(.day, from: $0) == 1 })
                || index == 0 else { return "" }
        let date = weeks[index].compactMap({ $0 }).first { calendar.component(.day, from: $0) == 1 } ?? first
        return date.formatted(.dateTime.month(.defaultDigits))
    }

    private func weekdayLabel(_ row: Int) -> String {
        let calendar = Calendar.current
        let weekday = (calendar.firstWeekday - 1 + row) % 7
        // Every other day, as GitHub labels them.
        guard row % 2 == 1 else { return "" }
        return calendar.veryShortWeekdaySymbols[weekday]
    }

    /// `count` weeks ending with this one, each seven days from the
    /// calendar's first weekday; days after today are nil.
    static func weeks(count: Int) -> [[Date?]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekday = calendar.component(.weekday, from: today)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        guard let thisWeek = calendar.date(byAdding: .day, value: -offset, to: today),
              let start = calendar.date(byAdding: .weekOfYear, value: -(count - 1), to: thisWeek) else { return [] }
        return (0..<count).map { column in
            (0..<7).map { row in
                guard let date = calendar.date(byAdding: .day, value: column * 7 + row, to: start), date <= today else { return nil }
                return date
            }
        }
    }
}
