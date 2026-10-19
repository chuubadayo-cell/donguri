//
//  BehaviorViews.swift
//  Donguri
//
//  操作 (gestures, haptics, auto-refresh) and 通知 settings.
//

import SwiftUI
import UIKit

struct BehaviorSettingsView: View {
    @State private var behavior = BehaviorSettings.shared

    var body: some View {
        List {
            Section {
                Toggle("画面のどこからでもスワイプで戻る", isOn: $behavior.fullSwipeBack)
                Toggle("触覚フィードバック", isOn: $behavior.haptics)
            } header: {
                Text("操作")
            } footer: {
                Text("オンにすると、画面の左端だけでなくどこからでも右にスワイプして前の画面に戻れます。スレ一覧のスワイプ操作（お気に入り・非表示）は左スワイプです。")
            }

            Section {
                Picker("更新の間隔", selection: $behavior.autoRefreshInterval) {
                    ForEach(BehaviorSettings.refreshIntervals, id: \.self) { seconds in
                        Text("\(seconds)秒").tag(seconds)
                    }
                }
                Toggle("実況板では自動でオン", isOn: $behavior.autoRefreshLiveBoards)
                Toggle("新着レスまで自動でスクロール", isOn: $behavior.followNewPosts)
            } header: {
                Text("スレの自動更新")
            } footer: {
                Text("自動更新は、スレの右上のメニューか右下のボタンを長押しして切り替えます。一番下まで読んでいるときは、新着レスが届くと自動でスクロールします。1000に達したスレでは止まります。")
            }
        }
        .navigationTitle("操作")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NotificationSettingsView: View {
    @State private var behavior = BehaviorSettings.shared
    @State private var denied = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Toggle("お気に入りスレの新着", isOn: Binding(
                    get: { behavior.notifyNewPosts },
                    set: { enable(\.notifyNewPosts, $0) }
                ))
                if behavior.notifyNewPosts {
                    Picker("通知する新着の数", selection: $behavior.notifyThreshold) {
                        ForEach(BehaviorSettings.notifyThresholds, id: \.self) { count in
                            Text("\(count)件以上").tag(count)
                        }
                    }
                }
            } footer: {
                Text("お気に入りに登録したスレに新しいレスがつくと通知します。")
            }

            Section {
                Toggle("次スレが立ったとき", isOn: Binding(
                    get: { behavior.notifyNextThread },
                    set: { enable(\.notifyNextThread, $0) }
                ))
                if behavior.notifyNextThread {
                    Toggle("次スレをお気に入りに追加", isOn: $behavior.autoFavoriteNextThread)
                }
            } footer: {
                Text("お気に入りのスレが1000に達するか落ちたあと、同じ板に続きのスレが立つと通知します。")
            }

            if denied {
                Section {
                    Button("設定アプリで通知を許可") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    }
                } footer: {
                    Text("通知が許可されていません。")
                }
            }

            Section {
                Button("テスト通知を送る") {
                    Task {
                        if await FavoriteWatcher.shared.requestAuthorization() {
                            await FavoriteWatcher.shared.sendTest()
                        } else {
                            denied = true
                        }
                    }
                }
                Button("今すぐ確認") {
                    Task { await FavoriteWatcher.shared.check() }
                }
                .disabled(!behavior.anyNotifications)
            } footer: {
                Text("確認はバックグラウンドで定期的に行われます。間隔はiOSが決めるため、すぐには届かないことがあります。「設定」アプリでこのアプリの「Appのバックグラウンド更新」がオンになっている必要があります。")
            }
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func enable(_ keyPath: ReferenceWritableKeyPath<BehaviorSettings, Bool>, _ on: Bool) {
        behavior[keyPath: keyPath] = on
        guard on else {
            FavoriteWatcher.shared.schedule()
            return
        }
        Task {
            let granted = await FavoriteWatcher.shared.requestAuthorization()
            denied = !granted
            FavoriteWatcher.shared.schedule()
        }
    }
}
