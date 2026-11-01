//
//  MangaReaderSettingsView.swift
//  Donguri
//
//  The manga reader's settings: how pages are shown, and how their text
//  is found and tapped. Opened from the reader's gear and from the マンガ
//  tab.
//

import SwiftUI

struct MangaReaderSettingsView: View {
    /// The title being read, for a reading mode of its own.
    var seriesID: String?
    var suggested: MangaReadingMode?

    @Environment(\.dismiss) private var dismiss
    @State private var settings = MangaReaderSettings.shared
    @State private var clearedCache = false

    var body: some View {
        NavigationStack {
            Form {
                if let seriesID {
                    Section {
                        Picker("この作品の読み方", selection: Binding(
                            get: { settings.mode(for: seriesID, suggested: suggested) },
                            set: { settings.setMode($0, for: seriesID) })) {
                            ForEach(MangaReadingMode.allCases) { Text(verbatim: $0.label).tag($0) }
                        }
                    }
                }

                Section {
                    Picker("読み方（既定）", selection: $settings.defaultMode) {
                        ForEach(MangaReadingMode.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    Picker("見開き", selection: $settings.spread) {
                        ForEach(MangaSpreadMode.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    if settings.spread != .off {
                        Toggle("表紙を単独で表示", isOn: $settings.coverAlone)
                    }
                    Picker("ページの合わせ方", selection: $settings.fit) {
                        ForEach(MangaPageFit.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    Picker("背景", selection: $settings.background) {
                        ForEach(MangaBackground.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                } header: {
                    Text("表示")
                }

                Section {
                    Toggle("画面の端をタップしてページをめくる", isOn: $settings.tapZones)
                    Toggle("ページ番号を表示", isOn: $settings.showPageNumber)
                    Toggle("読んでいる間はスリープしない", isOn: $settings.keepAwake)
                    Stepper(value: $settings.preload, in: 1...8) {
                        Text("先読み: \(settings.preload)ページ")
                    }
                } header: {
                    Text("操作")
                } footer: {
                    Text("端のタップは、マンガの向きでは左が次のページです。")
                }

                Section {
                    Toggle("自動で文字認識", isOn: $settings.autoOCR)
                    Picker("文字認識エンジン", selection: $settings.ocrEngine) {
                        Text("端末（Apple Vision）").tag(MangaOCREngine.vision)
                        Text(verbatim: "Google Cloud Vision").tag(MangaOCREngine.google)
                    }
                    if settings.ocrEngine == .google {
                        SecureField(text: $settings.googleAPIKey) {
                            Text("APIキー")
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    Picker("文字をタップしたとき", selection: $settings.textTap) {
                        ForEach(MangaTextTap.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    Toggle("吹き出しの枠を表示", isOn: $settings.showTextBoxes)
                    Picker("カードの画像", selection: $settings.cardPicture) {
                        ForEach(MangaCardPicture.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    Button(clearedCache ? "消去しました" : "文字認識の結果を消去") {
                        MangaOCR.clearCache()
                        clearedCache = true
                    }
                    .disabled(clearedCache)
                } header: {
                    Text("文字認識")
                } footer: {
                    if settings.ocrEngine == .google {
                        Text("ページの画像が Google に送られます。縦書きや手書き風の文字は端末の認識よりずっと正確です。APIキーは Google Cloud のコンソールで Cloud Vision API を有効にして作成します（月1000枚まで無料）。キーがないか使えないときは端末で認識します。")
                    } else {
                        Text("mokuro の文字があるページはそれを使います。ないページは開いたときに読み取り、結果を保存するので、二度目からはすぐに表示されます。長押しで吹き出しの文章を開けます。")
                    }
                }
            }
            .navigationTitle(Text("リーダーの設定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
