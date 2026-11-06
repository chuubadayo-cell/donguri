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
import AVKit
import UniformTypeIdentifiers

struct VideoPlayerView: View {
    /// Shrunk to the miniplayer above the tab bar.
    let minimized: Bool
    let onMinimize: () -> Void
    let onExpand: () -> Void
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
    /// Read only by `PullDownOffset`: as plain state, every point of a
    /// pull redrew the whole player, and the pull stuttered.
    @State private var pull = PullDown()
    /// The video's height, to tell a swipe from a drag on the scrubber.
    @State private var videoHeight: CGFloat = 0
    /// The last tap on the video, to tell a double tap without making
    /// single taps wait for it.
    @State private var lastTap: (time: Date, forward: Bool, controlsWereVisible: Bool)?
    /// A transcript line being corrected.
    @State private var editingCue: SubtitleCue?

    private enum Pane: String, CaseIterable {
        case transcript, comments, related
    }

    private struct SeekFlash: Equatable {
        let id = UUID()
        let forward: Bool
        let label: String
    }

    /// Space the miniplayer leaves for the tab bar.
    @State private var tabBarHeight: CGFloat = TabBarMetrics.heightAboveSafeArea()

    // Minimizing and expanding are one motion: a single number (`dock`)
    // says how far the video has travelled between the full player and
    // its place in the miniplayer, the finger or a spring moves it, and
    // everything on screen is worked out from it. What travels is a copy
    // of the video drawn above the player (`MovingVideo`), so the real one
    // never has to be small: YouTube's web view can't be.
    @State private var dock: VideoDock
    /// A finger is on a drag. Resets by itself when iOS cancels the touch,
    /// which `onEnded` never hears about.
    @GestureState private var dragging = false
    /// The full player is the form in charge of the screen.
    @State private var presentedFull: Bool
    /// The full player exists at all.
    @State private var fullMounted: Bool
    /// The real video has been let go of by the full player.
    @State private var surfaceInMini: Bool
    @State private var containerSize = CGSize(width: 390, height: 800)
    /// Where the video lands in the miniplayer.
    @State private var miniSlot = CGRect(x: 14, y: 640, width: 112, height: 63)
    /// The latest move, so a finished one that has been overtaken does
    /// nothing.
    @State private var formChange = 0
    /// Closing: the player animates itself away, then is removed with no
    /// animation of its own (two transitions at once left a grey ghost of
    /// the miniplayer behind and made closing stutter).
    @State private var closing = false

    init(item: VideoItem, minimized: Bool = false, onMinimize: @escaping () -> Void = {},
         onExpand: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        _model = State(initialValue: VideoPlayerModel(item: item))
        _dock = State(initialValue: VideoDock(minimized: minimized))
        _presentedFull = State(initialValue: !minimized)
        _fullMounted = State(initialValue: !minimized)
        _surfaceInMini = State(initialValue: minimized)
        self.minimized = minimized
        self.onMinimize = onMinimize
        self.onExpand = onExpand
        self.onClose = onClose
    }

    /// Full or mini, the same view (and model) throughout, so the video
    /// never stops between the two.
    var body: some View {
        ZStack {
            // YouTube's page while the miniplayer shows: kept full size and
            // in the window (so it plays on), behind the whole app. Shown
            // small, WebKit drew it black or white, and on top at 1% opacity
            // it showed as a grey ghost over light screens; the miniplayer
            // shows frames taken from its video instead (MovingVideo).
            if surfaceInMini, model.engine == .web, let web = model.web {
                WebPlayerParking(webView: web.webView)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            if fullMounted {
                fullPlayer
                    .modifier(FullPlayerDocking(dock: dock, height: containerSize.height))
                    .allowsHitTesting(presentedFull)
                    .accessibilityHidden(!presentedFull)
            }
            miniPlayer
                .modifier(MiniPlayerDocking(dock: dock))
                .allowsHitTesting(!presentedFull)
                .accessibilityHidden(presentedFull)
            MovingVideo(dock: dock, size: containerSize, slot: miniSlot,
                        player: model.engine == .web ? nil : model.player,
                        web: model.engine == .web ? model.web : nil,
                        active: surfaceInMini)
        }
        .coordinateSpace(name: Self.space)
        .offset(y: closing ? (presentedFull ? containerSize.height : 140) : 0)
        .opacity(closing ? 0 : 1)
        .allowsHitTesting(!closing)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
        .task {
            await model.start()
            scheduleHide()
        }
        .onDisappear {
            PictureInPicture.shared.setWanted(false)
            model.stop()
            OrientationLock.returnToPortrait()
        }
        // Leaving the app floats the video, whichever form it's in.
        .onChange(of: model.isPlaying, initial: true) { _, playing in
            PictureInPicture.shared.setWanted(playing)
        }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { scheduleHide() } else { showControls(autoHide: false) }
            model.refreshNowPlaying()
        }
        // The lock screen follows the video and the engine playing it.
        .onChange(of: model.phase) { model.refreshNowPlaying() }
        .onChange(of: model.engine) { model.refreshNowPlaying() }
        .onChange(of: model.title) { model.refreshNowPlaying() }
        .onChange(of: minimized) { _, isMinimized in
            if isMinimized { collapse() } else { expand() }
        }
        .onChange(of: dragging) { _, isDragging in
            guard !isDragging else { return }
            Task {
                // `onEnded` comes around now too, and goes first if it comes.
                try? await Task.sleep(for: .milliseconds(60))
                guard dock.dragStart != nil else { return }
                dock.dragStart = nil
                settle(to: presentedFull ? 0 : 1)
            }
        }
    }

    private static let space = "videoDock"

    /// How far the finger has to bring the video, in points.
    private var dockDistance: CGFloat { max(miniSlot.minY, 100) }

    /// The full player to the miniplayer, wherever the motion has got to.
    private func collapse() {
        model.popups.closeAll()
        OrientationLock.returnToPortrait()
        formChange += 1
        let change = formChange
        guard containerSize.width > containerSize.height else {
            finishCollapse()
            return
        }
        // Sideways: the screen turns first, then the video leaves.
        Task {
            for _ in 0..<60 where containerSize.width > containerSize.height {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard formChange == change else { return }
            finishCollapse()
        }
    }

    private func finishCollapse() {
        // Measured now: the miniplayer has been waiting since it was
        // built, perhaps sideways, where the tab bar is shorter.
        tabBarHeight = TabBarMetrics.heightAboveSafeArea()
        dock.begin()
        presentedFull = false
        settle(to: 1)
    }

    /// The miniplayer to the full player. A drag up has already mounted it.
    private func expand() {
        let wasMounted = fullMounted
        prepareFull()
        presentedFull = true
        let change = formChange
        Task {
            // Laid out behind the moving video first.
            if !wasMounted { try? await Task.sleep(for: .milliseconds(20)) }
            guard formChange == change else { return }
            settle(to: 0)
        }
    }

    /// The real video goes back to the full player, under the moving copy.
    private func prepareFull() {
        formChange += 1
        dock.begin()
        dock.surfaceReturning = true
        surfaceInMini = false
        fullMounted = true
    }

    /// The spring that finishes the motion, starting at the finger's speed
    /// so there is no join where the hand lets go.
    private func settle(to target: CGFloat) {
        formChange += 1
        let change = formChange
        let remaining = abs(target - dock.progress) * dockDistance
        let velocity = min(max(remaining > 1 ? dock.takeVelocity() / remaining : 0, -4), 8)
        withAnimation(.interpolatingSpring(duration: 0.42, bounce: 0, initialVelocity: velocity)) {
            dock.progress = target
        } completion: {
            guard formChange == change else { return }
            if target == 1 {
                surfaceInMini = true
                fullMounted = false
                dock.surfaceReturning = false
                dock.end()
            } else {
                land()
            }
        }
    }

    /// Back at full size: the copy gives way to the real video, which is
    /// the same picture in the same place.
    private func land() {
        let change = formChange
        Task {
            if dock.surfaceReturning {
                dock.surfaceReturning = false
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard formChange == change else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                dock.fading = true
            } completion: {
                guard formChange == change else { return }
                dock.end()
            }
            showControls(autoHide: true)
        }
    }

    /// Slides the player away, then lets the app remove it.
    private func close() {
        guard !closing else { return }
        model.popups.closeAll()
        model.pause()
        OrientationLock.returnToPortrait()
        withAnimation(.easeIn(duration: 0.2)) {
            closing = true
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { onClose() }
        }
    }

    /// Shrinks to the miniplayer, leaving full screen first.
    private func minimize() {
        model.popups.closeAll()
        OrientationLock.returnToPortrait()
        onMinimize()
    }

    private var fullPlayer: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            // One layout for both forms, so turning the screen resizes the
            // video instead of building it again: the web view must stay
            // where it is, and iOS can turn a backgrounded app while its
            // video floats, which left the page broken on return.
            VStack(spacing: 0) {
                videoArea(fullScreen: landscape)
                    .frame(height: landscape ? nil : geometry.size.width * 9 / 16)
                    .frame(maxWidth: .infinity, maxHeight: landscape ? .infinity : nil)
                    .background(Color.black)
                    .modifier(PullDownOffset(pull: pull))
                    .simultaneousGesture(pullDownGesture(fullScreen: landscape))
                if !landscape {
                    portraitBody
                }
            }
            .background(landscape ? Color.black : Color(.systemBackground))
            .statusBarHidden(landscape)
            .persistentSystemOverlays(landscape ? .hidden : .automatic)
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
        .overlay(alignment: .bottom) {
            if let notice = model.cardNotice {
                cardNoticeView(notice)
            }
        }
        .overlay(alignment: .center) {
            if let toast = model.toast {
                Text(verbatim: toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .overlay {
            PopupStackLayer(stack: model.popups)
        }
        .fileImporter(isPresented: $importingSubtitles,
                      allowedContentTypes: SubtitleFileTypes.all,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importSubtitles(from: url)
            }
        }
        // Covers the tabs underneath, status bar and home indicator too.
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: Miniplayer

    /// The video small above the tab bar, as in the YouTube app: tap or
    /// swipe up to open it again, swipe down or ✕ to close.
    private var miniPlayer: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            miniBar
                .padding(.horizontal, 8)
                .padding(.bottom, tabBarHeight + 6)
        }
        .onAppear { tabBarHeight = TabBarMetrics.heightAboveSafeArea() }
    }

    private var miniBar: some View {
        HStack(spacing: 10) {
            // The moving video lands here.
            Color.clear
                .frame(width: 112, height: 63)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { miniSlot = $0 }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: model.title.isEmpty ? String(localized: "動画") : model.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                // The line being said, or the channel.
                Text(verbatim: model.activeCue?.text.replacingOccurrences(of: "\n", with: " ") ?? model.channel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.isPlaying ? Text("一時停止") : Text("再生"))
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("閉じる"))
        }
        .buttonStyle(.plain)
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
        .overlay(alignment: .bottom) {
            MiniProgress(clock: model.clock)
                .padding(.horizontal, 10)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onExpand() }
        .gesture(miniDrag)
    }

    /// Up: the video follows the finger back to full size. Down: closes.
    private var miniDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                let height = value.translation.height
                if dock.dragStart == nil, height < 0, -height > abs(value.translation.width) {
                    dock.dragStart = height
                    prepareFull()
                }
                guard let start = dock.dragStart else { return }
                dock.setProgress(1 + (height - start) / dockDistance)
            }
            .onEnded { value in
                guard dock.dragStart != nil else {
                    if value.translation.height > 40 { close() }
                    return
                }
                dock.dragStart = nil
                dock.velocity = -value.velocity.height
                if dock.progress < 0.75 || value.velocity.height < -500 {
                    onExpand()
                } else {
                    dock.velocity = value.velocity.height
                    settle(to: 1)
                }
            }
    }

    /// The real video, in the full player.
    @ViewBuilder
    private var fullSurface: some View {
        if model.engine == .web, let web = model.web {
            WebPlayerSurface(webView: web.webView, active: !surfaceInMini)
        } else {
            PlayerSurface(player: model.player, active: !surfaceInMini)
        }
    }

    // MARK: Video

    private func videoArea(fullScreen: Bool) -> some View {
        ZStack {
            fullSurface

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
                    .animation(.easeOut(duration: 0.14), value: model.activeCue?.id)
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
        // The controls and subtitles go with the real video while its copy
        // is away, rather than fading out in mid-air.
        .overlay { VideoCover(dock: dock) }
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { videoHeight = $0 }
    }

    /// Swipe down on the video: in portrait the video follows the finger
    /// into the miniplayer, in full screen it leaves full screen, as in the
    /// YouTube app.
    /// Swipe left or right: the next or previous subtitle line.
    private func pullDownGesture(fullScreen: Bool) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                let down = value.translation.height
                if !fullScreen, let start = dock.dragStart {
                    dock.setProgress((down - start) / dockDistance)
                    return
                }
                // Only a mostly vertical, downward drag (not scrubbing).
                guard down > 0, down > abs(value.translation.width) * 1.4 else {
                    pull.set(0)
                    return
                }
                if fullScreen {
                    pull.set(min(down * 0.5, 120))
                } else {
                    // Measured from here, so the video doesn't jump.
                    formChange += 1
                    dock.dragStart = down
                    model.popups.closeAll()
                    dock.begin()
                }
            }
            .onEnded { value in
                if !fullScreen, dock.dragStart != nil {
                    dock.dragStart = nil
                    dock.velocity = value.velocity.height
                    if dock.progress > 0.2 || value.velocity.height > 700 {
                        onMinimize()
                    } else {
                        dock.velocity = -value.velocity.height
                        settle(to: 0)
                    }
                    return
                }
                let down = value.translation.height
                let across = value.translation.width
                // Sideways: a line forward (swipe left) or back (swipe
                // right), except on the scrubber, which drags the same way.
                let onScrubber = controlsVisible && value.startLocation.y > videoHeight - (fullScreen ? 64 : 52)
                if !onScrubber, abs(across) > abs(down) * 1.4,
                   abs(across) > 60 || (abs(value.predictedEndTranslation.width) > 180 && abs(across) > 24) {
                    if pull.value != 0 { withAnimation(.snappy) { pull.set(0) } }
                    let forward = across < 0
                    if forward { model.nextCue() } else { model.previousCue() }
                    if model.cues.isEmpty {
                        flash(forward: forward, label: forward ? "+10s" : "-10s")
                    } else {
                        flash(forward: forward, label: forward ? String(localized: "次の字幕") : String(localized: "前の字幕"))
                    }
                    return
                }
                let flicked = value.predictedEndTranslation.height > 260
                let vertical = down > abs(value.translation.width) * 1.4
                if fullScreen, vertical, down > 110 || (flicked && down > 30) {
                    withAnimation(.snappy) { pull.set(0) }
                    OrientationLock.rotate(to: .portrait)
                } else {
                    withAnimation(.snappy) { pull.set(0) }
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

    /// Why a card came out without its sentence audio, readable on the
    /// phone. Tap to dismiss.
    private func cardNoticeView(_ notice: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("文の音声を取得できませんでした", systemImage: "speaker.slash")
                .font(.footnote.weight(.semibold))
            Text(verbatim: notice)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
        .padding(.horizontal, 12)
        .padding(.bottom, 40)
        .onTapGesture { model.dismissCardNotice() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                    close()
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
                SubtitleTextView(text: cue.text,
                                 fontSize: fullScreen ? settings.subtitleSize * 1.2 : settings.subtitleSize * 0.85,
                                 scanNonJapaneseText: userConfig.scanNonJapaneseText,
                                 lookupOpen: !model.popups.isEmpty,
                                 onTextSelected: { selection in lookUp(selection, in: cue) },
                                 onTapOutside: { model.popups.closeAll() })
                    .blur(radius: blurred ? 7 : 0)
                    .allowsHitTesting(!blurred)
                    // An overlay, not a sibling in a stack: a clear view takes
                    // all the width it's offered, which stretched the backing
                    // of a blurred line across the whole video.
                    .overlay {
                        if blurred {
                            // Tap the blurred line to read it.
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { reveal(cue) }
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
            // One line fades into the next rather than snapping.
            .id(cue.id)
            .transition(.opacity)
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
                        minimize()
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("最小化"))
                    if fullScreen {
                        Text(verbatim: model.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                    if PictureInPicture.shared.isSupported {
                        Button {
                            PictureInPicture.shared.start()
                        } label: {
                            Image(systemName: "pip.enter")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("ピクチャ・イン・ピクチャ"))
                    }
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
                Toggle(isOn: $settings.autoPause) {
                    Label("字幕ごとに一時停止", systemImage: "pause.circle")
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
                    }
                    // The picker is this section's header, which a plain
                    // list keeps pinned to the top while its rows scroll.
                    Section {
                        switch pane {
                        case .transcript:
                            transcriptRows
                        case .comments:
                            commentRows
                        case .related:
                            ForEach(model.related) { video in
                                Button {
                                    AppNavigator.shared.playVideo(.youtube(id: video.id, title: video.title))
                                } label: {
                                    YouTubeVideoRow(video: video, compact: true)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        withAnimation(.snappy) { model.markNotInterested(video) }
                                    } label: {
                                        Label("興味なし", systemImage: "hand.thumbsdown")
                                    }
                                }
                            }
                        }
                    } header: {
                        Picker("", selection: $pane.animation(.snappy(duration: 0.25))) {
                            Text("字幕").tag(Pane.transcript)
                            if model.videoID != nil {
                                Text("コメント").tag(Pane.comments)
                                Text("次の動画").tag(Pane.related)
                            }
                        }
                        .pickerStyle(.segmented)
                        .textCase(nil)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                        .listRowInsets(EdgeInsets())
                    }
                }
                .listStyle(.plain)
                .sheet(item: $editingCue) { cue in
                    CueEditor(cue: cue) { text in model.editCue(cue, text: text) }
                }
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

    /// Title, channel, one line of numbers, then the buttons, all
    /// centred.
    private var header: some View {
        VStack(spacing: 6) {
            Text(verbatim: model.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if !model.channel.isEmpty {
                Button {
                    guard let channelID = model.channelID else { return }
                    minimize()
                    AppNavigator.shared.showYouTubeChannel(id: channelID, name: model.channel)
                } label: {
                    Text(verbatim: model.channel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.channelID == nil)
            }
            if !infoLine.isEmpty {
                Text(verbatim: infoLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            if model.videoID != nil {
                actionRow
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .animation(.easeOut(duration: 0.2), value: infoLine)
    }

    /// 12万回 · 登録者3.4万 · 2024/5/1
    private var infoLine: String {
        var parts: [String] = []
        if let views = model.viewCount, let count = Int(views) {
            parts.append(String(localized: "\(count.formatted(.number.notation(.compactName)))回"))
        }
        if let subscribers = Self.shortSubscribers(model.subscriberText) {
            parts.append(String(localized: "登録者\(subscribers)"))
        }
        if let date = model.publishDate {
            parts.append(date.formatted(.dateTime.year().month(.defaultDigits).day()))
        }
        return parts.joined(separator: " · ")
    }

    /// "チャンネル登録者数 12.3万人" → "12.3万".
    private static func shortSubscribers(_ text: String?) -> String? {
        guard let text, let match = text.firstMatch(of: /[\d][\d.,]*\s*[万億千KMBkmb]?/) else { return nil }
        return String(match.output).replacingOccurrences(of: " ", with: "")
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if model.channelID != nil {
                actionPill(systemImage: model.subscribed ? "bell.fill" : "bell",
                           title: model.subscribed ? String(localized: "登録済み") : String(localized: "登録"),
                           active: model.subscribed) {
                    model.toggleSubscribe()
                }
            }
            actionPill(systemImage: model.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                       title: likeLabel, active: model.liked) {
                model.toggleLike()
            }
            .accessibilityLabel(model.liked ? Text("高評価を取り消す") : Text("高評価"))
            actionPill(systemImage: model.inWatchLater ? "clock.fill" : "clock",
                       title: String(localized: "後で見る"), active: model.inWatchLater) {
                model.toggleWatchLater()
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The like count including the account's own like.
    private var likeLabel: String {
        guard let count = model.likeCount else { return String(localized: "高評価") }
        return (count + (model.liked ? 1 : 0)).formatted(.number.notation(.compactName))
    }

    private func actionPill(systemImage: String, title: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(verbatim: title)
                    .contentTransition(.numericText())
            } icon: {
                Image(systemName: systemImage)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: active)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .background(Capsule().fill(active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: active)
    }

    // MARK: Comments

    @ViewBuilder
    private var commentRows: some View {
        if let count = model.commentCount, !model.comments.isEmpty {
            Text("コメント \(count)件")
                .font(.subheadline.weight(.semibold))
                .listRowSeparator(.hidden)
        }
        ForEach(model.comments) { comment in
            CommentRow(comment: comment,
                       textStyle: AppearanceSettings.shared.postStyle,
                       onSelect: { selection in lookUpText(selection) },
                       onTapOutside: { model.popups.closeAll() })
            .equatable()
            .onAppear {
                if comment.id == model.comments.last?.id {
                    Task { await model.loadMoreComments() }
                }
            }
            if let replies = model.replies[comment.id] {
                ForEach(replies) { reply in
                    CommentRow(comment: reply,
                               textStyle: AppearanceSettings.shared.postStyle,
                               onSelect: { selection in lookUpText(selection) },
                               onTapOutside: { model.popups.closeAll() })
                        .equatable()
                        .padding(.leading, 40)
                        .listRowSeparator(.hidden)
                }
            }
            if comment.replyCount > 0 || model.replies[comment.id] != nil {
                repliesButton(comment)
                    .listRowSeparator(.hidden)
            }
        }
        if model.commentsLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        } else if model.commentsFailed {
            VStack(spacing: 8) {
                Text("コメントを読み込めませんでした")
                    .foregroundStyle(.secondary)
                Button("再試行") { Task { await model.retryComments() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
        } else if model.commentsLoaded, model.comments.isEmpty {
            Text("コメントはありません（オフになっている動画もあります）")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }
        // Loads when the tab is first shown.
        Color.clear
            .frame(height: 1)
            .listRowSeparator(.hidden)
            .task { await model.loadComments() }
    }

    private func repliesButton(_ comment: YTComment) -> some View {
        let shown = model.replies[comment.id]
        let loading = model.repliesLoading.contains(comment.id)
        return HStack(spacing: 10) {
            if shown == nil {
                Button {
                    Task { await model.loadReplies(for: comment) }
                } label: {
                    Label("返信 \(comment.replyCount)件", systemImage: "chevron.down")
                }
            } else {
                if model.hasMoreReplies(comment) {
                    Button {
                        Task { await model.loadReplies(for: comment) }
                    } label: {
                        Label("さらに返信を表示", systemImage: "arrow.turn.down.right")
                    }
                }
                Button {
                    model.hideReplies(for: comment)
                } label: {
                    Label("返信を隠す", systemImage: "chevron.up")
                }
            }
            if loading { ProgressView().controlSize(.small) }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Color.accentColor)
        .buttonStyle(.borderless)
        .padding(.leading, 40)
    }

    /// A word in a comment: looked up like any text, without a clip.
    private func lookUpText(_ selection: SelectionData) -> Int? {
        model.prepareTextLookup()
        return model.popups.replace(with: selection, userConfig: userConfig)
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
            let currentID = model.cues[safe: model.lastCueIndex]?.id
            ForEach(model.cues) { cue in
                TranscriptRow(cue: cue,
                              isCurrent: cue.id == currentID,
                              blurred: isBlurred(cue),
                              textStyle: AppearanceSettings.shared.postStyle,
                              onSeek: {
                                  // Jumping to a line picks the transcript's
                                  // following back up from there.
                                  followTranscript = true
                                  model.play(cue)
                              },
                              onReveal: { reveal(cue) },
                              onSelect: { selection in lookUp(selection, in: cue) },
                              onTapOutside: { model.popups.closeAll() },
                              onEdit: {
                                  model.popups.closeAll()
                                  editingCue = cue
                              })
                    // Only the rows whose line, highlight or blur changed
                    // redraw when playback moves on a line.
                    .equatable()
                    .id(cue.id)
            }
        }
    }
}

private struct TranscriptRow: View, Equatable {
    let cue: SubtitleCue
    let isCurrent: Bool
    let blurred: Bool
    let textStyle: PostTextStyle
    let onSeek: () -> Void
    let onReveal: () -> Void
    let onSelect: (SelectionData) -> Int?
    let onTapOutside: () -> Void
    let onEdit: () -> Void
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
                         style: textStyle,
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
        // Long press: fix a mis-heard line before mining from it.
        .contextMenu {
            Button(action: onEdit) {
                Label("字幕を編集", systemImage: "pencil")
            }
            Button {
                UIPasteboard.general.string = cue.text
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
            Button(action: onSeek) {
                Label("ここから再生", systemImage: "play")
            }
        }
    }

    /// The closures are rebuilt on every redraw but do the same thing.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cue == rhs.cue && lhs.isCurrent == rhs.isCurrent && lhs.blurred == rhs.blurred
            && lhs.textStyle.key == rhs.textStyle.key
    }
}

/// The miniplayer's picture for YouTube's page: frames drawn from its
/// video element about 30 times a second (the same drawing a card's
/// screenshot uses, smaller and lighter).
/// Corrects one transcript line: automatic captions often mishear the
/// very word worth mining.
private struct CueEditor: View {
    let cue: SubtitleCue
    let onSave: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(cue: SubtitleCue, onSave: @escaping (String) -> Void) {
        self.cue = cue
        self.onSave = onSave
        _text = State(initialValue: cue.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("字幕", text: $text, axis: .vertical)
                        .lineLimit(2...8)
                        .focused($focused)
                } header: {
                    Text(verbatim: cue.timeLabel)
                } footer: {
                    Text("直した字幕はこの動画に保存され、カードの例文にも使われます。")
                }
            }
            .navigationTitle(Text("字幕を編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

/// A comment: the author's picture and name, when, the text (tap a word
/// to look it up), and its likes.
private struct CommentRow: View, Equatable {
    let comment: YTComment
    let textStyle: PostTextStyle
    let onSelect: (SelectionData) -> Int?
    let onTapOutside: () -> Void
    @Environment(UserConfig.self) private var userConfig

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let photo = comment.authorPhoto {
                    RemoteThumbnail(url: photo)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: comment.author)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let published = comment.published {
                        Text(verbatim: published)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                PostTextView(text: comment.text,
                             scanNonJapaneseText: userConfig.scanNonJapaneseText,
                             style: textStyle,
                             onTextSelected: onSelect,
                             onTapOutside: onTapOutside,
                             onPostReply: { _ in },
                             onThreadRoute: { _ in })
                if let likes = comment.likes {
                    Label(likes, systemImage: "hand.thumbsup")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.comment == rhs.comment && lhs.textStyle.key == rhs.textStyle.key
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

/// Keeps YouTube's page playing while nothing shows it: at the very back
/// of the window, under the app's opaque root view.
private struct WebPlayerParking: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> Parking { Parking(webView: webView) }
    func updateUIView(_ view: Parking, context: Context) {}

    final class Parking: UIView {
        let webView: WKWebView
        private weak var parkedIn: UIWindow?

        init(webView: WKWebView) {
            self.webView = webView
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                webView.removeFromSuperview()
                webView.transform = .identity
                webView.frame = CGRect(x: 0, y: 0, width: 390, height: 219)
                window.insertSubview(webView, at: 0)
                parkedIn = window
            } else if webView.superview === parkedIn {
                // Leaving, and no player claimed it: the page is done.
                webView.removeFromSuperview()
            }
        }
    }
}

/// YouTube's own player, styled down to its video.
/// One web view moves between the full player and the miniplayer, so
/// it's hosted in a container that takes it over when shown.
private struct WebPlayerSurface: UIViewRepresentable {
    let webView: WKWebView
    /// This is the place the video is drawn now.
    var active = true

    func makeUIView(context: Context) -> WebHost {
        let host = WebHost(webView: webView)
        host.active = active
        host.claim()
        return host
    }

    func updateUIView(_ host: WebHost, context: Context) {
        host.active = active
        host.claim()
    }

    final class WebHost: UIView {
        let webView: WKWebView
        var active = true
        /// The page's size when shown large. Small hosts (the miniplayer)
        /// shrink the page as a picture instead of resizing it: YouTube's
        /// page laid out a few dozen points wide stopped drawing its video
        /// and showed white.
        private static var pageSize = CGSize(width: 390, height: 219)
        private static let smallWidth: CGFloat = 240

        init(webView: WKWebView) {
            self.webView = webView
            super.init(frame: .zero)
            backgroundColor = .black
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func claim() {
            guard active, window != nil || webView.superview == nil, webView.superview !== self else { return }
            webView.removeFromSuperview()
            webView.autoresizingMask = []
            addSubview(webView)
            place()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { claim() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if webView.superview === self { place() }
        }

        private func place() {
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return }
            if size.width >= Self.smallWidth {
                Self.pageSize = size
                webView.transform = .identity
                webView.frame = bounds
            } else {
                let page = Self.pageSize
                let scale = min(size.width / page.width, size.height / page.height)
                webView.transform = .identity
                webView.bounds = CGRect(origin: .zero, size: page)
                webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
                webView.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
    }
}

/// The one number behind minimizing and expanding: 0 is the full player, 1
/// the miniplayer. Kept out of the player's own state so a drag redraws
/// only what moves.
@Observable
private final class VideoDock {
    var progress: CGFloat
    /// The copy is above the player, in motion or about to be.
    private(set) var moving = false
    /// The copy is fading into the real video underneath.
    var fading = false
    /// Where the finger started counting from, during a drag.
    @ObservationIgnored var dragStart: CGFloat?
    /// The finger's speed as it let go, points a second towards the form
    /// being moved to.
    @ObservationIgnored var velocity: CGFloat = 0
    /// The real video has just gone back to the full player and needs a
    /// moment to draw.
    @ObservationIgnored var surfaceReturning = false

    init(minimized: Bool) {
        progress = minimized ? 1 : 0
    }

    func begin() {
        fading = false
        if !moving { moving = true }
    }

    func end() {
        moving = false
        fading = false
    }

    /// Follows the finger, with no animation.
    func setProgress(_ value: CGFloat) {
        progress = min(max(value, 0), 1)
    }

    func takeVelocity() -> CGFloat {
        defer { velocity = 0 }
        return velocity
    }
}

/// The video that travels. At rest in the full player it waits underneath,
/// already drawing, so a drag has a picture from its first moment.
private struct MovingVideo: View {
    let dock: VideoDock
    let size: CGSize
    let slot: CGRect
    /// The native player, drawn through a second layer.
    let player: AVPlayer?
    /// YouTube's page, whose frames are drawn instead.
    let web: YouTubeWebPlayer?
    let active: Bool
    @State private var frame: UIImage?

    private var showing: Bool { dock.moving || dock.progress > 0 }

    var body: some View {
        MovingVideoHost(progress: dock.progress, size: size, slot: slot,
                        player: player, active: active, frame: frame)
            .opacity(dock.fading ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(showing ? 2 : -1)
            .task(id: web.map(ObjectIdentifier.init)) { await collectFrames() }
    }

    private func collectFrames() async {
        guard let web else {
            frame = nil
            return
        }
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let started = clock.now
            let moving = dock.moving
            let resting = !moving && dock.progress == 0
            // A frame now and then at rest, so one is ready when a drag
            // starts. Few while it travels: fetching one takes the main
            // thread, and nobody can follow the picture then anyway.
            if UIApplication.shared.applicationState == .active,
               let next = await web.miniFrame(maxWidth: moving || resting ? 480 : 240) {
                frame = next
            }
            let interval: Duration = moving ? .milliseconds(90)
                : resting ? .milliseconds(400)
                : web.state.paused ? .milliseconds(250) : .milliseconds(33)
            let wait = interval - (clock.now - started)
            if wait > .zero { try? await Task.sleep(for: wait) } else { await Task.yield() }
        }
    }
}

/// Places the video: as wide as the screen at 0, on the miniplayer's slot
/// at 1. A UIKit view moved by a transform, so a spring runs in iOS's own
/// animation process and stays smooth whatever the main thread is doing,
/// where anything animated by SwiftUI waits for it.
private struct MovingVideoHost: UIViewRepresentable {
    let progress: CGFloat
    let size: CGSize
    let slot: CGRect
    let player: AVPlayer?
    let active: Bool
    let frame: UIImage?

    func makeUIView(context: Context) -> MovingVideoView { MovingVideoView() }

    func updateUIView(_ view: MovingVideoView, context: Context) {
        if let player {
            PlayerSurface(player: player, active: active, mirror: true).sync(view.playerView)
        }
        view.playerView.isHidden = player == nil
        view.imageView.isHidden = player != nil
        if view.imageView.image !== frame { view.imageView.image = frame }
        view.setWidth(size.width)
        let placement = MovingVideoView.Placement(progress: progress, width: size.width, slot: slot)
        guard view.placement != placement else { return }
        // Takes over the animation SwiftUI's withAnimation asked for.
        context.animate { view.place(placement) }
    }
}

private final class MovingVideoView: UIView {
    struct Placement: Equatable {
        let progress: CGFloat
        let width: CGFloat
        let slot: CGRect
    }

    private(set) var placement: Placement?
    let playerView = PlayerSurface.PlayerLayerView()
    let imageView = UIImageView()
    private let stage = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        stage.backgroundColor = .black
        stage.clipsToBounds = true
        stage.layer.cornerCurve = .continuous
        // Scaled and moved from its top left corner.
        stage.layer.anchorPoint = .zero
        stage.layer.position = .zero
        playerView.playerLayer.videoGravity = .resizeAspect
        imageView.contentMode = .scaleAspectFit
        addSubview(stage)
        stage.addSubview(playerView)
        stage.addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Laid out once at full size, and only ever transformed after that.
    func setWidth(_ width: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: width * 9 / 16)
        guard stage.bounds != bounds else { return }
        stage.bounds = bounds
        playerView.frame = bounds
        imageView.frame = bounds
    }

    func place(_ placement: Placement) {
        self.placement = placement
        let p = min(max(placement.progress, 0), 1)
        let width = max(placement.width, 1)
        let scale = 1 + (placement.slot.width / width - 1) * p
        stage.transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                            tx: placement.slot.minX * p, ty: placement.slot.minY * p)
        // Counter-scaled, so it ends as the slot's own 8-point corners.
        stage.layer.cornerRadius = 8 * p / scale
    }
}

/// Hides the real video in the full player while its copy is away. Gone as
/// the copy fades, or the copy would fade into this instead of the video.
private struct VideoCover: View {
    let dock: VideoDock

    var body: some View {
        if (dock.moving || dock.progress > 0), !dock.fading {
            Color.black.allowsHitTesting(false)
        }
    }
}

/// The full player sinks and fades as the video leaves it.
private struct FullPlayerDocking: ViewModifier {
    let dock: VideoDock
    let height: CGFloat

    func body(content: Content) -> some View {
        content.modifier(Fade(progress: dock.progress, height: height))
    }

    struct Fade: ViewModifier, Animatable {
        var progress: CGFloat
        let height: CGFloat

        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            let p = min(max(progress, 0), 1)
            content
                .opacity(1 - min(p / 0.45, 1))
                .offset(y: p * height * 0.3)
        }
    }
}

/// The miniplayer's bar comes in under the video as it arrives.
private struct MiniPlayerDocking: ViewModifier {
    let dock: VideoDock

    func body(content: Content) -> some View {
        content.modifier(Fade(progress: dock.progress))
    }

    struct Fade: ViewModifier, Animatable {
        var progress: CGFloat

        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            let p = min(max(progress, 0), 1)
            content
                .opacity(max((p - 0.6) / 0.4, 0))
                .offset(y: (1 - p) * 20)
        }
    }
}

/// How far the full-screen player is pulled down, kept out of the player's
/// own state so a pull redraws only what moves.
@Observable
private final class PullDown {
    private(set) var value: CGFloat = 0

    /// Writes only a change: every assignment notifies.
    func set(_ newValue: CGFloat) {
        if value != newValue { value = newValue }
    }
}

private struct PullDownOffset: ViewModifier {
    let pull: PullDown

    func body(content: Content) -> some View {
        content.offset(y: pull.value)
    }
}

/// The playback position as a thin line along the miniplayer.
private struct MiniProgress: View {
    let clock: PlaybackClock

    var body: some View {
        GeometryReader { geometry in
            let progress = clock.duration > 0 ? min(max(clock.time / clock.duration, 0), 1) : 0
            Capsule()
                .fill(Color.red)
                .frame(width: geometry.size.width * progress, height: 2)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

/// How far the tab bar reaches above the home indicator, so the
/// miniplayer can sit just above it.
enum TabBarMetrics {
    static func heightAboveSafeArea() -> CGFloat {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let tabBar = find(in: window), !tabBar.isHidden else { return 49 }
        let frame = tabBar.convert(tabBar.bounds, to: window)
        return max(0, window.bounds.height - frame.minY - window.safeAreaInsets.bottom)
    }

    private static func find(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar { return tabBar }
        for subview in view.subviews {
            if let found = find(in: subview) { return found }
        }
        return nil
    }
}

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    /// This is the place the video is drawn now.
    var active = true
    /// Keeps drawing the player even while another layer is the main one.
    var mirror = false

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        sync(view)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        sync(view)
    }

    func sync(_ view: PlayerLayerView) {
        // Not while parked in the background (see PlayerLayerView).
        guard UIApplication.shared.applicationState != .background else { return }
        let wanted: AVPlayer? = active || mirror ? player : nil
        if view.playerLayer.player !== wanted { view.playerLayer.player = wanted }
        let becameActive = active && !view.isMain
        view.isMain = active
        if becameActive {
            if view.pictureInPicture == nil {
                view.pictureInPicture = PictureInPicture.shared.attach(view.playerLayer)
            } else {
                PictureInPicture.shared.use(view.pictureInPicture)
            }
        }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        /// iOS's floating player, started by AVKit when the app is left.
        var pictureInPicture: AVPictureInPictureController?
        /// The layer Picture in Picture goes through.
        var isMain = false
        private var parked: AVPlayer?
        private var observers: [NSObjectProtocol] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            // A player still showing its picture is paused by iOS when the
            // app leaves the screen; let go of it there to keep the sound.
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        // Floating in Picture in Picture, the picture stays.
                        guard let self, VideoSettings.shared.backgroundPlayback,
                              !PictureInPicture.shared.isActive,
                              self.pictureInPicture?.isPictureInPictureActive != true else { return }
                        self.parked = self.playerLayer.player
                        self.playerLayer.player = nil
                    }
                },
                center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let parked = self.parked else { return }
                        self.playerLayer.player = parked
                        self.parked = nil
                    }
                },
            ]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        isolated deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
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
