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
    @AppStorage("iroha.video.autoPiP") private var autoPiP = true

    var body: some View {
        Form {
            qualitySection

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
                Toggle("全画面からアプリを離れたらピクチャ・イン・ピクチャ", isOn: $autoPiP)
                    .onChange(of: autoPiP) { _, on in PictureInPicture.shared.enabled = on }
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
        .task {
            await model?.refreshQualities()
        }
    }

    /// The highest quality to play. With a video open, only what it
    /// offers, and what it plays at now.
    private var qualitySection: some View {
        Section {
            Picker("画質", selection: Binding(get: { settings.videoQuality },
                                             set: { id in
                                                 if let model { model.setQuality(id) } else { settings.videoQuality = id }
                                             })) {
                Text("自動").tag("auto")
                ForEach(qualityChoices, id: \.self) { id in
                    Text(verbatim: VideoSettings.qualityLabel(id)).tag(id)
                }
            }
            if let model, !model.currentQuality.isEmpty {
                LabeledContent("再生中", value: VideoSettings.qualityLabel(model.currentQuality))
            }
        } header: {
            Text("画質")
        } footer: {
            Text("選んだ画質か、ない場合はそれより下の一番よい画質で再生します。")
        }
    }

    private var qualityChoices: [String] {
        var ids = VideoSettings.qualities.map { $0.id }.filter { $0 != "auto" }
        if let model, !model.availableQualities.isEmpty { ids = model.availableQualities }
        // The setting stays choosable even if this video lacks it.
        if settings.videoQuality != "auto", !ids.contains(settings.videoQuality) { ids.append(settings.videoQuality) }
        let order = ["highres"] + VideoSettings.qualities.map { $0.id }
        return ids.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
    }
}
