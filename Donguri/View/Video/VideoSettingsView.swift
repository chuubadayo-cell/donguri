//
//  VideoSettingsView.swift
//  Donguri
//
//  Subtitle display and what cards mined from videos get.
//

import SwiftUI

struct VideoSettingsView: View {
    /// The video playing, when opened from the player.
    var model: VideoPlayerModel? = nil
    @State private var settings = VideoSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("字幕を表示", isOn: $settings.showSubtitles)
                Picker("字幕の位置", selection: $settings.subtitlePosition) {
                    Text("下").tag(VideoSettings.SubtitlePosition.bottom)
                    Text("上").tag(VideoSettings.SubtitlePosition.top)
                }
                VStack(alignment: .leading) {
                    LabeledContent("文字の大きさ", value: "\(Int(settings.subtitleSize))pt")
                    Slider(value: $settings.subtitleSize, in: 14...32, step: 1)
                }
                Toggle("字幕をぼかす", isOn: $settings.blurSubtitles)
                if settings.blurSubtitles {
                    Toggle("一時停止中はぼかさない", isOn: $settings.unblurWhenPaused)
                }
            } header: {
                Text("字幕")
            } footer: {
                Text("ぼかした字幕はタップすると読めます。聞き取りの練習に。")
            }

            Section {
                Toggle("調べるときに一時停止", isOn: $settings.pauseOnLookup)
                Toggle("ダブルタップで前後の字幕へ", isOn: $settings.doubleTapSeeksLines)
                Toggle("字幕ごとに一時停止", isOn: $settings.autoPause)
                Toggle("バックグラウンド再生", isOn: $settings.backgroundPlayback)
            } header: {
                Text("操作")
            } footer: {
                Text("動画を左右にスワイプしても前後の字幕へ移れます。ダブルタップをオフにすると、10秒戻る・進むになります。「字幕ごとに一時停止」は、各字幕の終わりで止まります。")
            }

            Section {
                Picker("画像", selection: $settings.cardImage) {
                    Text("スクリーンショット").tag(ClipImageKind.screenshot)
                    Text("GIF").tag(ClipImageKind.gif)
                    Text("なし").tag(ClipImageKind.none)
                }
                Toggle("字幕の音声", isOn: $settings.cardAudio)
                Stepper(value: $settings.paddingBefore, in: 0...2000, step: 50) {
                    LabeledContent("前の余白", value: "\(settings.paddingBefore)ms")
                }
                Stepper(value: $settings.paddingAfter, in: 0...2000, step: 50) {
                    LabeledContent("後ろの余白", value: "\(settings.paddingAfter)ms")
                }
            } header: {
                Text("Ankiのカード")
            } footer: {
                Text("字幕から追加したカードには、その字幕の時間（＋余白）の音声と、スクリーンショットまたはGIFが付きます。Ankiの設定で、音声は {sentence-audio}、画像は {book-cover} の欄に入ります。")
            }

            if let model, !model.cues.isEmpty {
                Section {
                    HStack {
                        Button {
                            model.subtitleDelay -= 0.1
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Text(verbatim: String(format: "%+.1fs", model.subtitleDelay))
                            .monospacedDigit()
                        Spacer()
                        Button {
                            model.subtitleDelay += 0.1
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("字幕のずれ（この動画）")
                }
            }
        }
        .navigationTitle(Text("動画と字幕"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
