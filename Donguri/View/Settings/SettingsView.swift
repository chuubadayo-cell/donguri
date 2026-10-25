//
//  SettingsView.swift
//  Donguri
//
//  Created by John Connery on 8/18/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// False when shown as a tab rather than a sheet.
    var showsCloseButton = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        StatsView()
                    } label: {
                        StatsSummaryRow()
                    }
                }

                Section {
                    NavigationLink {
                        DictionaryView()
                    } label: {
                        Label("辞書", systemImage: "character.book.closed.ja")
                    }
                    NavigationLink {
                        AnkiView()
                    } label: {
                        Label("Anki", systemImage: "rectangle.on.rectangle.angled")
                    }
                    NavigationLink {
                        VideoSettingsView()
                    } label: {
                        Label("動画と字幕", systemImage: "captions.bubble")
                    }
                } header: {
                    Text("辞書とマイニング")
                }

                Section {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        Label("外観", systemImage: "textformat")
                    }
                    NavigationLink {
                        MediaSettingsView()
                    } label: {
                        Label("画像と動画", systemImage: "photo.on.rectangle")
                    }
                    NavigationLink {
                        NGFilterView()
                    } label: {
                        Label("NG設定", systemImage: "hand.raised")
                    }
                } header: {
                    Text("表示")
                } footer: {
                    Text("画像の先読みとキャッシュ、特定の語句・ID・名前を含む書き込みやスレの非表示を設定します。")
                }

                Section {
                    NavigationLink {
                        BehaviorSettingsView()
                    } label: {
                        Label("操作", systemImage: "hand.draw")
                    }
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("通知", systemImage: "bell.badge")
                    }
                    NavigationLink {
                        BackupView()
                    } label: {
                        Label("バックアップ", systemImage: "externaldrive.badge.timemachine")
                    }
                } header: {
                    Text("アプリ")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if showsCloseButton {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}

/// 学習の記録's entry: today's numbers at a glance.
private struct StatsSummaryRow: View {
    @State private var store = StatsStore.shared

    var body: some View {
        let today = store.day(.now)
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text("学習の記録")
                    .font(.headline)
                Text("今日 \(StatsStore.formatMinutes(StatsStore.Metric.watchTime.value(today)))・\(today.lookups)語調べた・\(today.cards)枚追加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}
