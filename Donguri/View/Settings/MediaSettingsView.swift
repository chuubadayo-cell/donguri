//
//  MediaSettingsView.swift
//  Donguri
//
//  画像と動画: preloading, and the image / thread caches.
//

import SwiftUI

struct MediaSettingsView: View {
    @AppStorage(MediaPrefetchMode.defaultsKey) private var prefetchRaw = MediaPrefetchMode.nearby.rawValue

    @State private var cachedBytes: Int64?
    @State private var pinnedBytes: Int64?
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Picker("先読み", selection: $prefetchRaw) {
                    ForEach(MediaPrefetchMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            } header: {
                Text("画像の先読み")
            } footer: {
                Text("「近くの画像のみ」は、スクロールに合わせて少し先の画像を読み込みます。「すべて」はスレを開いた時点でスレ内の画像をすべて読み込みます（Wi-Fi時のみ、またはモバイル通信でも）。")
            }

            Section {
                LabeledContent("キャッシュ") {
                    sizeText(cachedBytes)
                }
                LabeledContent("オフライン保存した画像") {
                    sizeText(pinnedBytes)
                }
                Button("キャッシュを消去", role: .destructive) {
                    confirmClear = true
                }
            } header: {
                Text("ストレージ")
            } footer: {
                Text("キャッシュは1GBを超えると古いものから自動的に削除されます。オフライン保存したスレの画像は、そのスレを削除するまで残ります。")
            }
        }
        .navigationTitle("画像と動画")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("画像とスレのキャッシュを消去しますか？",
                            isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("キャッシュを消去", role: .destructive) {
                Task {
                    await MediaStore.shared.clearCache()
                    await DatCache.shared.clear()
                    await refreshSizes()
                }
            }
        } message: {
            Text("オフライン保存したスレとその画像は消えません。")
        }
        .task {
            await refreshSizes()
        }
    }

    private func sizeText(_ bytes: Int64?) -> some View {
        Group {
            if let bytes {
                Text(bytes.formatted(.byteCount(style: .file)))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func refreshSizes() async {
        let sizes = await MediaStore.shared.cacheSizeBytes()
        cachedBytes = sizes.cached
        pinnedBytes = sizes.pinned
    }
}
