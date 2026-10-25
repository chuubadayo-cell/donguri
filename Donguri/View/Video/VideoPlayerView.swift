//
//  VideoPlayerView.swift
//  Donguri
//
//  The video player, laid out like the YouTube app (video on top, details
//  and the transcript below; full screen when turned sideways), with
//  asbplayer's tools for mining: subtitles over the video at the top or
//  bottom, optionally blurred until tapped; jumping line by line; and
//  cards that get the line's audio and a screenshot or GIF.
//
//  The quick way to mine a word you just heard: tap the video to pause (or
//  tap the word in the subtitle, which pauses), step back a line with ⟨ if
//  it's already gone, tap the word, press + in the popup.
//

import SwiftUI
import AVFoundation
import WebKit
import UniformTypeIdentifiers

struct VideoPlayerView: View {
    let onClose: () -> Void
    @State private var model: VideoPlayerModel
    @State private var settings = VideoSettings.shared
    @Environment(UserConfig.self) private var userConfig

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showsSettings = false
    @State private var importingSubtitles = false
    @State private var pane: Pane = .transcript
    @State private var followTranscript = true
    @State private var seekFlash: SeekFlash?
    /// How far the player has been pulled down (swipe down to minimize).
    @State private var pullDown: CGFloat = 0
    /// The last tap on the video, to tell a double tap without making
    /// single taps wait for it.
    @State private var lastTap: (time: Date, forward: Bool, controlsWereVisible: Bool)?

    private enum Pane: String, CaseIterable {
        case transcript, related
    }

    private struct SeekFlash: Equatable {
        let id = UUID()
        let forward: Bool
        let label: String
    }

    init(item: VideoItem, onClose: @escaping () -> Void) {
        _model = State(initialValue: VideoPlayerModel(item: item))
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            Group {
                if landscape {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        videoArea(fullScreen: true)
                            .offset(y: pullDown)
                            .simultaneousGesture(pullDownGesture(fullScreen: true))
                    }
                    .statusBarHidden(true)
                    .persistentSystemOverlays(.hidden)
                } else {
                    VStack(spacing: 0) {
                        videoArea(fullScreen: false)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .background(Color.black)
                            .simultaneousGesture(pullDownGesture(fullScreen: false))
                        portraitBody
                    }
                    .background(Color(.systemBackground))
                    .offset(y: pullDown)
                    .opacity(1 - Double(min(pullDown / 600, 0.4)))
                }
            }
            // On its own view: a sheet and a file importer on the same
            // view fight, and the settings sheet never opened.
            .sheet(isPresented: $showsSettings) {
                NavigationStack {
                    VideoSettingsView(model: model)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完了") { showsSettings = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .overlay {
            PopupStackLayer(stack: model.popups)
        }
        .task {
            await model.start()
            scheduleHide()
        }
        .onDisappear {
            model.stop()
            OrientationLock.returnToPortrait()
        }
        .fileImporter(isPresented: $importingSubtitles,
                      allowedContentTypes: SubtitleFileTypes.all,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importSubtitles(from: url)
            }
        }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { scheduleHide() } else { showControls(autoHide: false) }
        }
    }

    // MARK: Video

    private func videoArea(fullScreen: Bool) -> some View {
        ZStack {
            if model.engine == .web, let web = model.web {
                WebPlayerSurface(webView: web.webView)
            } else {
                PlayerSurface(player: model.player)
            }

            // Taps: one shows or hides the controls; two on either side
            // jump a line (or ten seconds) back or forward.
            HStack(spacing: 0) {
                tapZone(forward: false)
                tapZone(forward: true)
            }

            if let flash = seekFlash {
                HStack {
                    if flash.forward { Spacer() }
                    Label(flash.label, systemImage: flash.forward ? "forward.fill" : "backward.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .padding(.horizontal, 40)
                    if !flash.forward { Spacer() }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if !model.isAd {
                subtitleOverlay(fullScreen: fullScreen)
            }

            if model.isAd {
                adBadge(fullScreen: fullScreen)
            }

            if model.isMakingCard {
                VStack {
                    Label("カード用に録音中…", systemImage: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        .padding(.top, fullScreen ? 16 : 8)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            controls(fullScreen: fullScreen)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)

            switch model.phase {
            case .loading:
                ProgressView().tint(.white).controlSize(.large)
            case .failed(let message):
                failure(message)
            case .ready:
                if model.isBuffering {
                    ProgressView().tint(.white).controlSize(.large).allowsHitTesting(false)
                }
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    /// Swipe down on the video: in portrait it minimizes (closes) the
    /// player, in full screen it leaves full screen, as in the YouTube app.
    private func pullDownGesture(fullScreen: Bool) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                let down = value.translation.height
                // Only a mostly vertical, downward drag (not scrubbing).
                guard down > 0, down > abs(value.translation.width) * 1.4 else {
                    if pullDown != 0 { pullDown = 0 }
                    return
                }
                pullDown = fullScreen ? min(down * 0.5, 120) : down
            }
            .onEnded { value in
                let down = value.translation.height
                let flicked = value.predictedEndTranslation.height > 260
                let vertical = down > abs(value.translation.width) * 1.4
                if vertical, down > 110 || (flicked && down > 30) {
                    if fullScreen {
                        withAnimation(.snappy) { pullDown = 0 }
                        OrientationLock.rotate(to: .portrait)
                    } else {
                        withAnimation(.easeIn(duration: 0.18)) { pullDown = 900 }
                        Task {
                            try? await Task.sleep(for: .milliseconds(170))
                            onClose()
                        }
                    }
                } else {
                    withAnimation(.snappy) { pullDown = 0 }
                }
            }
    }

    /// A tap answers at once (controls in or out); a second tap on the
    /// same side within a moment is a double tap, which jumps, and puts the
    /// controls back how they were. SwiftUI's own double-tap gesture made
    /// every single tap wait a third of a second first.
    private func tapZone(forward: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                let now = Date.now
                if let last = lastTap, last.forward == forward, now.timeIntervalSince(last.time) < 0.3 {
                    lastTap = nil
                    if last.controlsWereVisible { showControls(autoHide: true) } else { hideControls() }
                    if settings.doubleTapSeeksLines, !model.cues.isEmpty {
                        if forward { model.nextCue() } else { model.previousCue() }
                        flash(forward: forward, label: forward ? String(localized: "次の字幕") : String(localized: "前の字幕"))
                    } else {
                        model.skip(by: forward ? 10 : -10)
                        flash(forward: forward, label: forward ? "+10s" : "-10s")
                    }
                    return
                }
                lastTap = (now, forward, controlsVisible)
                if !model.popups.isEmpty {
                    model.popups.closeAll()
                } else if controlsVisible {
                    hideControls()
                } else {
                    showControls(autoHide: true)
                }
            }
    }

    private func flash(forward: Bool, label: String) {
        withAnimation(.easeOut(duration: 0.15)) { seekFlash = SeekFlash(forward: forward, label: label) }
        let current = seekFlash
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if seekFlash == current { withAnimation { seekFlash = nil } }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
            if let id = model.videoID, let url = URL(string: "https://m.youtube.com/watch?v=\(id)") {
                Button("ブラウザで開く") {
                    onClose()
                    AppNavigator.shared.openInBrowser(url, allowNativePlayer: false)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    // MARK: Subtitles over the video

    @ViewBuilder
    private func subtitleOverlay(fullScreen: Bool) -> some View {
        if settings.showSubtitles, let cue = model.activeCue {
            let blurred = isBlurred(cue)
            VStack {
                if settings.subtitlePosition == .bottom { Spacer() }
                ZStack {
                    SubtitleTextView(text: cue.text,
                                     fontSize: fullScreen ? settings.subtitleSize * 1.2 : settings.subtitleSize * 0.85,
                                     scanNonJapaneseText: userConfig.scanNonJapaneseText,
                                     lookupOpen: !model.popups.isEmpty,
                                     onTextSelected: { selection in lookUp(selection, in: cue) },
                                     onTapOutside: { model.popups.closeAll() })
                        .blur(radius: blurred ? 7 : 0)
                        .allowsHitTesting(!blurred)
                    if blurred {
                        // Tap the blurred line to read it.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                reveal(cue)
                            }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45)))
                .padding(.horizontal, fullScreen ? 48 : 10)
                .padding(settings.subtitlePosition == .bottom ? .bottom : .top,
                         controlsVisible ? (fullScreen ? 76 : 46) : (fullScreen ? 22 : 8))
                if settings.subtitlePosition == .top { Spacer() }
            }
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        }
    }

    /// Blurred until tapped (or paused, if that's the setting).
    private func isBlurred(_ cue: SubtitleCue) -> Bool {
        settings.blurSubtitles && !model.revealedCueIDs.contains(cue.id)
            && !(settings.unblurWhenPaused && !model.isPlaying)
    }

    private func reveal(_ cue: SubtitleCue) {
        _ = withAnimation(.easeOut(duration: 0.15)) { model.revealedCueIDs.insert(cue.id) }
    }

    /// Shown → blurred → hidden, for every place subtitles appear.
    private func cycleSubtitleMode() {
        if !settings.showSubtitles {
            settings.showSubtitles = true
            settings.blurSubtitles = false
        } else if !settings.blurSubtitles {
            settings.blurSubtitles = true
            model.revealedCueIDs.removeAll()
        } else {
            settings.showSubtitles = false
        }
        Haptics.play(.selection)
    }

    private var subtitleModeIcon: String {
        if !settings.showSubtitles { return "eye.slash" }
        return settings.blurSubtitles ? "eye.trianglebadge.exclamationmark" : "eye"
    }

    private func adBadge(fullScreen: Bool) -> some View {
        VStack {
            Spacer()
            HStack {
                Text("広告")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow))
                Spacer()
                if model.canSkipAd {
                    Button {
                        model.skipAd()
                    } label: {
                        Label("スキップ", systemImage: "forward.end.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.black.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, fullScreen ? 40 : 12)
            .padding(.bottom, controlsVisible ? (fullScreen ? 70 : 44) : 12)
        }
    }

    private func lookUp(_ selection: SelectionData, in cue: SubtitleCue) -> Int? {
        model.prepareLookup(in: cue)
        let matched = model.popups.replace(with: selection, userConfig: userConfig)
        if matched != nil { hideTask?.cancel() }
        return matched
    }

    // MARK: Controls

    private func controls(fullScreen: Bool) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("閉じる"))
                    if fullScreen {
                        Text(verbatim: model.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                    captionMenu
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("設定"))
                }
                .padding(.horizontal, fullScreen ? 24 : 6)
                .padding(.top, fullScreen ? 8 : 2)

                Spacer()

                HStack(spacing: fullScreen ? 56 : 40) {
                    Button {
                        model.previousCue()
                        showControls(autoHide: true)
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.title2)
                            .frame(width: 56, height: 56)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("前の字幕"))
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: fullScreen ? 44 : 36))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 72, height: 72)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(model.isPlaying ? Text("一時停止") : Text("再生"))
                    Button {
                        model.nextCue()
                        showControls(autoHide: true)
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.title2)
                            .frame(width: 56, height: 56)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("次の字幕"))
                }

                Spacer()

                HStack(spacing: 10) {
                    TimeLabel(clock: model.clock)
                    Scrubber(clock: model.clock) { time in
                        model.seek(to: time)
                        showControls(autoHide: true)
                    }
                    Button {
                        model.replayCue()
                    } label: {
                        Image(systemName: "gobackward")
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("この字幕をもう一度"))
                    .disabled(model.cues.isEmpty)
                    Button {
                        toggleFullScreen(fullScreen)
                    } label: {
                        Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("全画面"))
                }
                .padding(.horizontal, fullScreen ? 20 : 4)
                .padding(.bottom, fullScreen ? 6 : 0)
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private var captionMenu: some View {
        Menu {
            Toggle(isOn: $settings.showSubtitles) {
                Label("字幕を表示", systemImage: "captions.bubble")
            }
            if !model.tracks.isEmpty {
                Section("字幕トラック") {
                    ForEach(model.tracks) { track in
                        Button {
                            Task { await model.loadSubtitles(track: track) }
                        } label: {
                            if track == model.selectedTrack {
                                Label(track.name, systemImage: "checkmark")
                            } else {
                                Text(verbatim: track.name)
                            }
                        }
                    }
                }
            }
            Button {
                importingSubtitles = true
            } label: {
                Label("字幕ファイルを読み込む", systemImage: "doc.badge.plus")
            }
            Section {
                Picker(selection: $settings.subtitlePosition) {
                    Text("下").tag(VideoSettings.SubtitlePosition.bottom)
                    Text("上").tag(VideoSettings.SubtitlePosition.top)
                } label: {
                    Label("字幕の位置", systemImage: "arrow.up.and.down")
                }
                Toggle(isOn: $settings.blurSubtitles) {
                    Label("字幕をぼかす", systemImage: "eye.slash")
                }
            }
            Section("再生速度") {
                ForEach(VideoSettings.rates, id: \.self) { rate in
                    Button {
                        model.setRate(rate)
                    } label: {
                        if settings.playbackRate == rate {
                            Label(rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(verbatim: rateLabel(rate))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: model.cues.isEmpty ? "captions.bubble" : "captions.bubble.fill")
                .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("字幕"))
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == 1 ? String(localized: "標準") : String(format: "%gx", rate)
    }

    private func showControls(autoHide: Bool) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func hideControls() {
        hideTask?.cancel()
        controlsVisible = false
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, model.isPlaying, model.popups.isEmpty else { return }
            controlsVisible = false
        }
    }

    private func toggleFullScreen(_ isFullScreen: Bool) {
        OrientationLock.rotate(to: isFullScreen ? .portrait : .landscape)
        showControls(autoHide: true)
    }

    // MARK: Below the video

    private var portraitBody: some View {
        VStack(spacing: 0) {
            lineBar
            Divider()
            ScrollViewReader { proxy in
                List {
                    Section {
                        header
                            .listRowSeparator(.hidden)
                        Picker("", selection: $pane) {
                            Text("字幕").tag(Pane.transcript)
                            if model.videoID != nil {
                                Text("次の動画").tag(Pane.related)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                    }
                    switch pane {
                    case .transcript:
                        transcriptRows
                    case .related:
                        ForEach(model.related) { video in
                            Button {
                                AppNavigator.shared.playVideo(.youtube(id: video.id, title: video.title))
                            } label: {
                                YouTubeVideoRow(video: video, compact: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        followTranscript = false
                        if !model.popups.isEmpty { model.popups.closeAll() }
                    }
                }
                .onChange(of: model.lastCueIndex) { _, index in
                    guard followTranscript, pane == .transcript, let index, model.cues.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(model.cues[index].id, anchor: .center)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followTranscript, pane == .transcript, !model.cues.isEmpty {
                        Button {
                            followTranscript = true
                            if let index = model.lastCueIndex, model.cues.indices.contains(index) {
                                withAnimation { proxy.scrollTo(model.cues[index].id, anchor: .center) }
                            }
                        } label: {
                            Label("再生中の字幕へ", systemImage: "arrow.down.to.line")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(14)
                    }
                }
            }
        }
    }

    /// The line just heard, big, with the line-by-line controls: the place
    /// to tap a word you didn't catch.
    private var lineBar: some View {
        HStack(alignment: .center, spacing: 6) {
            Button {
                model.previousCue()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("前の字幕"))
            Group {
                if !settings.showSubtitles, !model.cues.isEmpty {
                    Text("字幕は非表示")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let index = model.lastCueIndex, model.cues.indices.contains(index) {
                    let cue = model.cues[index]
                    let blurred = isBlurred(cue)
                    PostTextView(text: cue.text,
                                 scanNonJapaneseText: userConfig.scanNonJapaneseText,
                                 style: AppearanceSettings.shared.postStyle,
                                 onTextSelected: { selection in lookUp(selection, in: cue) },
                                 onTapOutside: { model.popups.closeAll() },
                                 onPostReply: { _ in },
                                 onThreadRoute: { _ in })
                        .id(cue.id)
                        .opacity(model.activeCue?.id == cue.id ? 1 : 0.6)
                        .blur(radius: blurred ? 6 : 0)
                        .allowsHitTesting(!blurred)
                        .overlay {
                            if blurred {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { reveal(cue) }
                            }
                        }
                } else if model.loadingSubtitles {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("字幕を読み込み中…")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else if let error = model.subtitleError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if model.cues.isEmpty {
                    Text("字幕がありません。上の字幕ボタンからファイルも読み込めます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("再生すると、ここに字幕が出ます")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            Button {
                model.replayCue()
            } label: {
                Image(systemName: "gobackward")
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("この字幕をもう一度"))
            .disabled(model.cues.isEmpty)
            Button {
                model.nextCue()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("次の字幕"))
            Button {
                cycleSubtitleMode()
            } label: {
                Image(systemName: subtitleModeIcon)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("字幕の表示（表示・ぼかし・非表示）"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: model.title)
                .font(.headline)
                .lineLimit(3)
            HStack(spacing: 8) {
                if !model.channel.isEmpty {
                    if let channelID = model.channelID {
                        Button {
                            onClose()
                            AppNavigator.shared.showYouTubeChannel(id: channelID, name: model.channel)
                        } label: {
                            Text(verbatim: model.channel)
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(verbatim: model.channel)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                if let views = model.viewCount, let count = Int(views) {
                    Text("\(count)回視聴")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let source = model.subtitleSource {
                    Label(source, systemImage: "captions.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let id = model.videoID, let url = URL(string: "https://www.youtube.com/watch?v=\(id)") {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var transcriptRows: some View {
        if model.cues.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if model.loadingSubtitles {
                    ProgressView()
                } else {
                    Text("字幕がありません")
                        .foregroundStyle(.secondary)
                    Button {
                        importingSubtitles = true
                    } label: {
                        Label("字幕ファイルを読み込む", systemImage: "doc.badge.plus")
                    }
                }
            }
        } else if !settings.showSubtitles {
            VStack(alignment: .leading, spacing: 10) {
                Text("字幕は非表示です")
                    .foregroundStyle(.secondary)
                Button {
                    settings.showSubtitles = true
                } label: {
                    Label("字幕を表示", systemImage: "eye")
                }
            }
        } else {
            if model.subtitleDelay != 0 || model.item.isFile {
                DelayRow(model: model)
            }
            ForEach(model.cues) { cue in
                TranscriptRow(cue: cue,
                              isCurrent: cue.id == model.cues[safe: model.lastCueIndex]?.id,
                              blurred: isBlurred(cue),
                              onSeek: { model.play(cue) },
                              onReveal: { reveal(cue) },
                              onSelect: { selection in lookUp(selection, in: cue) },
                              onTapOutside: { model.popups.closeAll() })
                    .id(cue.id)
            }
        }
    }
}

private struct TranscriptRow: View {
    let cue: SubtitleCue
    let isCurrent: Bool
    let blurred: Bool
    let onSeek: () -> Void
    let onReveal: () -> Void
    let onSelect: (SelectionData) -> Int?
    let onTapOutside: () -> Void
    @Environment(UserConfig.self) private var userConfig

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onSeek) {
                Text(verbatim: cue.timeLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 50, alignment: .leading)
                    .padding(.top, 2)
            }
            .buttonStyle(.borderless)
            PostTextView(text: cue.text,
                         scanNonJapaneseText: userConfig.scanNonJapaneseText,
                         style: AppearanceSettings.shared.postStyle,
                         onTextSelected: onSelect,
                         onTapOutside: onTapOutside,
                         onPostReply: { _ in },
                         onThreadRoute: { _ in })
                .blur(radius: blurred ? 6 : 0)
                .allowsHitTesting(!blurred)
                .overlay {
                    if blurred {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onReveal)
                    }
                }
        }
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

/// Nudges file subtitles earlier or later.
private struct DelayRow: View {
    let model: VideoPlayerModel

    var body: some View {
        HStack {
            Text("字幕のずれ")
                .font(.footnote)
            Spacer()
            Button { model.subtitleDelay -= 0.25 } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
            Text(verbatim: String(format: "%+.2fs", model.subtitleDelay))
                .font(.footnote.monospacedDigit())
                .frame(width: 64)
            Button { model.subtitleDelay += 0.25 } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - Pieces

/// YouTube's own player, styled down to its video.
private struct WebPlayerSurface: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

private struct TimeLabel: View {
    let clock: PlaybackClock

    var body: some View {
        Text(verbatim: "\(Self.format(clock.time)) / \(Self.format(clock.duration))")
            .font(.caption2.monospacedDigit())
            .fixedSize()
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The position bar. Dragging previews the time and seeks on release.
private struct Scrubber: View {
    let clock: PlaybackClock
    let onSeek: (Double) -> Void
    @State private var dragTime: Double?

    var body: some View {
        GeometryReader { geometry in
            let duration = max(clock.duration, 0.1)
            let time = dragTime ?? clock.time
            let progress = min(max(time / duration, 0), 1)
            let buffered = min(max(clock.buffered / duration, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                Capsule().fill(.white.opacity(0.45)).frame(width: geometry.size.width * buffered, height: 3)
                Capsule().fill(Color.red).frame(width: geometry.size.width * progress, height: 3)
                Circle().fill(Color.red)
                    .frame(width: dragTime == nil ? 11 : 16, height: dragTime == nil ? 11 : 16)
                    .offset(x: geometry.size.width * progress - (dragTime == nil ? 5.5 : 8))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragTime = min(max(value.location.x / geometry.size.width, 0), 1) * duration
                    }
                    .onEnded { _ in
                        if let dragTime { onSeek(dragTime) }
                        dragTime = nil
                    }
            )
        }
        .frame(height: 28)
    }
}

enum SubtitleFileTypes {
    static var all: [UTType] {
        ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) } + [.plainText, .data]
    }
}

extension VideoItem {
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

extension Array {
    subscript(safe index: Int?) -> Element? {
        guard let index, indices.contains(index) else { return nil }
        return self[index]
    }
}
