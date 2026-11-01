//
//  MangaReaderView.swift
//  Donguri
//
//  The manga reader, after Suwayomi's (the reader Manatan builds on):
//  pages right to left or left to right, two-page spreads, or one long
//  vertical strip; fitted to the screen, width or height; tap zones to
//  turn pages, a page slider, and an end card leading to the next
//  chapter. Text, Manatan's way: every page is read as it comes up (mokuro
//  when the volume has it, else OCR, kept on disk), in speech bubbles. A
//  tap on a word looks it up; a long press opens the bubble's text as a
//  card whose words can be tapped too (or the other way round). Cards get
//  the bubble as their picture.
//

import SwiftUI

struct MangaReaderView: View {
    let request: ReaderRequest
    let onClose: () -> Void

    @Environment(UserConfig.self) private var userConfig
    @State private var settings = MangaReaderSettings.shared
    @State private var library = MangaLibrary.shared
    @State private var unitIndex: Int
    @State private var pages: [ReaderPage] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var loadAttempt = 0
    /// The slot on screen (a page, a spread, or the end card).
    @State private var currentID: String?
    @State private var showChrome = true
    @State private var isZoomed = false
    @State private var popups = PopupStack()
    @State private var toast: String?
    /// The controls were showing when zooming in, and come back after.
    @State private var chromeBeforeZoom = true
    @State private var texts = ReaderTexts()
    @State private var bubble: OpenBubble?
    @State private var showsSettings = false
    /// Reading text this session (starts from 自動で文字認識).
    @State private var ocrActive = MangaReaderSettings.shared.autoOCR
    @State private var isLandscape = false
    @State private var sliderPage: Double = 0
    @State private var draggingSlider = false
    /// The vertical strip doesn't follow a position given before it's laid
    /// out, so jumps there are made with its ScrollViewReader.
    @State private var stripJump = 0

    init(request: ReaderRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _unitIndex = State(initialValue: request.startIndex)
    }

    private var unit: ReaderUnit? {
        request.units.indices.contains(unitIndex) ? request.units[unitIndex] : nil
    }

    private var mode: MangaReadingMode {
        settings.mode(for: request.seriesID, suggested: request.suggestedMode)
    }

    private var usesSpreads: Bool {
        mode != .vertical && (settings.spread == .always || (settings.spread == .landscape && isLandscape))
    }

    private var endID: String { "\(unit?.id ?? "")#end" }

    /// Screens in reading order: single pages or spreads, then the end card.
    private var slots: [ReaderSlot] {
        var result: [ReaderSlot] = []
        var index = 0
        while index < pages.count {
            let wide = texts.isWide(pages[index].id)
            let alone = !usesSpreads || wide || (settings.coverAlone && index == 0) || index + 1 >= pages.count
                || texts.isWide(pages[index + 1].id)
            if alone {
                result.append(.pages([index], id: pages[index].id))
                index += 1
            } else {
                result.append(.pages([index, index + 1], id: pages[index].id))
                index += 2
            }
        }
        result.append(.end(id: endID))
        return result
    }

    private var currentPageIndex: Int? {
        guard let currentID else { return nil }
        for slot in slots {
            if case .pages(let indices, let id) = slot, id == currentID { return indices.first }
        }
        return pages.firstIndex { $0.id == currentID }
    }

    private var pageLabel: String? {
        guard let currentID else { return nil }
        for slot in slots {
            if case .pages(let indices, let id) = slot, id == currentID {
                let numbers = indices.map { String($0 + 1) }.joined(separator: "-")
                return "\(numbers) / \(pages.count)"
            }
        }
        return nil
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.gray)
                    .controlSize(.large)
            } else if let loadError {
                errorView(loadError)
            } else if mode == .vertical {
                verticalReader
            } else {
                pagedReader
            }

            if showChrome {
                chrome
                    .transition(.opacity)
            }

            if isZoomed && !showChrome {
                zoomBadge
                    .transition(.opacity)
            }

            if let bubble {
                BubbleCard(bubble: bubble,
                           onSelect: { selection in lookUp(selection, bubble: bubble) },
                           onTapOutside: { popups.closeAll() },
                           onCopy: {
                               UIPasteboard.general.string = bubble.text
                               flash(String(localized: "コピーしました"))
                           },
                           onClose: { closeBubble() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let toast {
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
        .animation(.snappy(duration: 0.25), value: bubble?.id)
        .overlay {
            PopupStackLayer(stack: popups)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        .statusBarHidden(!showChrome)
        .preferredColorScheme(settings.background == .white ? .light : .dark)
        .sheet(isPresented: $showsSettings) {
            MangaReaderSettingsView(seriesID: request.seriesID, suggested: request.suggestedMode)
                .presentationDetents([.medium, .large])
        }
        .task(id: "\(unitIndex)#\(loadAttempt)") {
            await loadUnit()
        }
        .onChange(of: currentID) { _, _ in
            if isZoomed { zoomChanged(false) }
            popups.closeAll()
            closeBubble()
            pageChanged()
        }
        .onChange(of: usesSpreads) { _, _ in
            // The spread holding the current page.
            if let index = currentPageIndex { show(page: index, animated: false) }
        }
        .onChange(of: mode) { _, _ in
            // The new layout has to exist before it can be scrolled to the
            // page that was on screen.
            guard let index = currentPageIndex else { return }
            currentID = nil
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                show(page: index, animated: false)
            }
        }
        .onChange(of: ocrActive) { _, _ in readText() }
        .onChange(of: texts.typicalRatio) { _, _ in
            // The strip's placeholders just took the pages' real shape.
            if mode == .vertical, let index = currentPageIndex { show(page: index, animated: false) }
        }
        .onChange(of: settings.ocrEngine) { _, _ in
            texts.clear()
            readText()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
            if ocrActive { TextRecognizer.warmUp() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            library.flush()
        }
    }

    private var backgroundColor: Color {
        switch settings.background {
        case .black: .black
        case .gray: Color(white: 0.2)
        case .white: .white
        }
    }

    private var foreground: Color {
        settings.background == .white ? .black : .white
    }

    // MARK: Readers

    private var pagedReader: some View {
        let rightToLeft = mode == .rightToLeft
        let all = slots
        let screenOrder = rightToLeft ? Array(all.reversed()) : all
        let pagerSlots: [PagerSlot] = screenOrder.map { slot in
            switch slot {
            case .pages(let indices, let id):
                let shown = indices.map { pages[$0] }
                return PagerSlot(id: id, pages: rightToLeft ? shown.reversed() : shown)
            case .end(let id):
                return PagerSlot(id: id, pages: [], isEnd: true)
            }
        }
        return MangaPager(slots: pagerSlots,
                          currentID: $currentID,
                          locked: isZoomed,
                          fit: settings.fit,
                          showsBoxes: settings.showTextBoxes,
                          highlighted: bubble,
                          textVersion: texts.version,
                          pageText: { [texts] page in texts.text(of: page) },
                          handlers: PagerHandlers(onTap: tapped,
                                                  onTextTap: textTapped,
                                                  onBubble: { page, block in openBubble(page: page, block: block) },
                                                  onZoomChange: zoomChanged,
                                                  onImage: { [texts] page, image in texts.noteSize(image.size, for: page.id) })) {
            endCard
        }
        .ignoresSafeArea()
    }

    /// While a page is zoomed in, a small reminder of how to get out; the
    /// controls are hidden and taps on the page only look up words.
    private var zoomBadge: some View {
        VStack {
            Spacer()
            Label("拡大中・ダブルタップで戻る", systemImage: "plus.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(.bottom, 14)
                .allowsHitTesting(false)
        }
    }

    private var verticalReader: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(pages) { page in
                    ReaderSlotView(pages: [page],
                                   rightToLeft: false,
                                   texts: texts,
                                   fit: .screen,
                                   zoomable: false,
                                   showsBoxes: settings.showTextBoxes,
                                   highlighted: bubble,
                                   onTap: { _ in toggleChrome() },
                                   onTextTap: textTapped,
                                   onBubble: { page, block in openBubble(page: page, block: block) })
                        .id(page.id)
                }
                endCard
                    .frame(height: 360)
                    .id(endID)
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $currentID, anchor: .top)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .onChange(of: stripJump) { _, _ in
            if let currentID { proxy.scrollTo(currentID, anchor: .top) }
        }
        .task {
            // Laid out now: go to where reading stopped.
            try? await Task.sleep(for: .milliseconds(30))
            if let currentID { proxy.scrollTo(currentID, anchor: .top) }
        }
        }
    }

    private var endCard: some View {
        VStack(spacing: 18) {
            if let unit {
                Text(verbatim: unit.label)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("読了")
                    .font(.subheadline)
                    .opacity(0.7)
            }
            if unitIndex + 1 < request.units.count {
                Button {
                    unitIndex += 1
                } label: {
                    VStack(spacing: 4) {
                        Text("次へ")
                            .font(.headline)
                        Text(verbatim: request.units[unitIndex + 1].label)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("最後の章です")
                    .font(.subheadline)
                    .opacity(0.7)
            }
            Button("閉じる") { close() }
                .buttonStyle(.bordered)
        }
        .foregroundStyle(foreground)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleChrome)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(verbatim: message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("再試行") { loadAttempt += 1 }
                    .buttonStyle(.borderedProminent)
                Button("閉じる") { close() }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(foreground)
        .padding(32)
    }

    // MARK: Controls

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if bubble == nil {
                bottomBar
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 2) {
            iconButton("xmark", label: Text("閉じる")) { close() }

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: request.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let unit {
                    Text(verbatim: unit.label)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if texts.reading > 0 {
                ProgressView()
                    .tint(.white)
                    .frame(width: 36, height: 44)
            }

            if !pages.allSatisfy({ $0.text != nil }) {
                iconButton("text.viewfinder", label: Text("文字認識"), tint: ocrActive ? .yellow : .white) {
                    ocrActive.toggle()
                    if ocrActive { TextRecognizer.warmUp() }
                    flash(ocrActive ? String(localized: "文字認識オン") : String(localized: "文字認識オフ"))
                }
            }

            Menu {
                if mode != .vertical {
                    Picker(selection: $settings.spread) {
                        ForEach(MangaSpreadMode.allCases) { Text(verbatim: $0.label).tag($0) }
                    } label: {
                        Label("見開き", systemImage: "book.pages")
                    }
                    .pickerStyle(.menu)
                    if settings.spread != .off {
                        Toggle(isOn: $settings.coverAlone) {
                            Label("表紙を単独で表示", systemImage: "book.closed")
                        }
                    }
                }
                Toggle(isOn: $settings.showTextBoxes) {
                    Label("吹き出しの枠を表示", systemImage: "rectangle.dashed")
                }
                if let index = currentPageIndex, pages.indices.contains(index), pages[index].text == nil, ocrActive {
                    Button {
                        rereadPage(index)
                    } label: {
                        Label("このページを読み直す", systemImage: "arrow.clockwise")
                    }
                }
                if let seriesID = request.seriesID {
                    Menu {
                        ForEach(MangaReadingMode.allCases) { option in
                            Button {
                                settings.setMode(option, for: seriesID)
                            } label: {
                                if option == mode {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: option.label)
                                }
                            }
                        }
                        if settings.hasOwnMode(seriesID) {
                            Button("既定に戻す") { settings.setMode(nil, for: seriesID) }
                        }
                    } label: {
                        Label("この作品の読み方", systemImage: "book")
                    }
                }
                if unitIndex > 0 {
                    Button {
                        unitIndex -= 1
                    } label: {
                        Label("前の章", systemImage: "backward.end")
                    }
                }
                if unitIndex + 1 < request.units.count {
                    Button {
                        unitIndex += 1
                    } label: {
                        Label("次の章", systemImage: "forward.end")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.headline)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }

            iconButton("gearshape", label: Text("設定")) { showsSettings = true }
        }
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.82).ignoresSafeArea(edges: .top))
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if settings.showPageNumber, let pageLabel {
                Text(verbatim: pageLabel)
                    .font(.footnote.monospacedDigit().weight(.semibold))
            }
            if pages.count > 1 {
                // Left and right follow the reading direction: in a manga
                // the next chapter is to the left.
                let rtl = mode == .rightToLeft
                let hasNext = unitIndex + 1 < request.units.count
                let hasPrevious = unitIndex > 0
                HStack(spacing: 10) {
                    iconButton("backward.end", label: rtl ? Text("次の章") : Text("前の章")) {
                        if rtl { if hasNext { unitIndex += 1 } } else if hasPrevious { unitIndex -= 1 }
                    }
                    .opacity((rtl ? hasNext : hasPrevious) ? 1 : 0.3)
                    Slider(value: $sliderPage, in: 0...Double(max(pages.count - 1, 1)), step: 1) { editing in
                        draggingSlider = editing
                        if !editing { show(page: Int(sliderPage), animated: false) }
                    }
                    .tint(.white)
                    // Manga turn the other way: the slider does too.
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                    iconButton("forward.end", label: rtl ? Text("前の章") : Text("次の章")) {
                        if rtl { if hasPrevious { unitIndex -= 1 } } else if hasNext { unitIndex += 1 }
                    }
                    .opacity((rtl ? hasPrevious : hasNext) ? 1 : 0.3)
                }
                .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color.black.opacity(0.82).ignoresSafeArea(edges: .bottom))
    }

    private func iconButton(_ systemImage: String, label: Text, tint: Color = .white,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Loading and moving

    private func loadUnit() async {
        guard let unit else { return }
        isLoading = true
        loadError = nil
        popups.closeAll()
        closeBubble()
        do {
            let loaded = try await request.pages(unit)
            guard !Task.isCancelled else { return }
            pages = loaded
            let saved = library.page(for: unit.id)
            // A finished chapter opens at its start again.
            let start = saved < loaded.count - 1 ? saved : 0
            isLoading = false
            show(page: start, animated: false)
            if let mangaID = request.mangaID, let key = unit.id.split(separator: "\u{1F}").last {
                library.setLastChapter(String(key), for: mangaID)
            }
        } catch {
            guard !Task.isCancelled else { return }
            loadError = (error as? LocalizedError)?.errorDescription ?? UserFacingError.message(for: error)
            isLoading = false
        }
    }

    /// Puts the page (or the spread holding it) on screen.
    private func show(page index: Int, animated: Bool) {
        guard pages.indices.contains(index) else { return }
        let id: String = mode == .vertical ? pages[index].id : slots.first { slot in
            if case .pages(let indices, _) = slot { indices.contains(index) } else { false }
        }?.id ?? pages[index].id
        if animated {
            withAnimation(.snappy(duration: 0.25)) { currentID = id }
        } else {
            currentID = id
        }
        if mode == .vertical { stripJump += 1 }
        sliderPage = Double(index)
    }

    private func pageChanged() {
        guard let unit, let index = currentPageIndex else {
            if currentID == endID, let unit { library.setPage(max(pages.count - 1, 0), of: pages.count, for: unit.id) }
            return
        }
        library.setPage(index, of: pages.count, for: unit.id)
        if let seriesID = request.seriesID { library.noteRead(seriesID) }
        if !draggingSlider { sliderPage = Double(index) }
        preload(around: index)
        readText()
    }

    private func turn(forward: Bool) {
        let all = slots
        guard let position = all.firstIndex(where: { $0.id == currentID }) else { return }
        let target = forward ? position + 1 : position - 1
        guard all.indices.contains(target) else { return }
        withAnimation(.snappy(duration: 0.22)) { currentID = all[target].id }
    }

    private func preload(around index: Int) {
        let ahead = max(settings.preload, 1)
        for neighbour in (index - 1)...(index + ahead) where pages.indices.contains(neighbour) && neighbour != index {
            let page = pages[neighbour]
            guard MangaImages.cached(page.id) == nil else { continue }
            Task { _ = try? await page.load() }
        }
    }

    /// Reads the text of the pages on screen and the next few, Manatan's
    /// way, so it's there by the time they're turned to.
    private func readText() {
        guard ocrActive, let index = currentPageIndex else { return }
        let ahead = max(settings.preload, 1)
        for neighbour in index...(index + ahead) where pages.indices.contains(neighbour) {
            let page = pages[neighbour]
            guard texts.text(of: page) == nil, !texts.isReading(page.id) else { continue }
            texts.startReading(page.id)
            let priority: TaskPriority = neighbour <= index + 1 ? .userInitiated : .utility
            Task(priority: priority) {
                if let cached = MangaOCR.cached(key: page.id) {
                    texts.finishReading(page.id, text: cached)
                    return
                }
                guard let image = try? await page.load() else {
                    texts.finishReading(page.id, text: nil)
                    return
                }
                let text = await MangaOCR.text(for: image, key: page.id, priority: priority)
                texts.finishReading(page.id, text: text)
            }
        }
    }

    private func rereadPage(_ index: Int) {
        let page = pages[index]
        MangaOCR.forget(key: page.id)
        texts.remove(page.id)
        readText()
    }

    // MARK: Taps

    private func tapped(_ fraction: CGFloat) {
        if !popups.isEmpty || bubble != nil {
            popups.closeAll()
            closeBubble()
            return
        }
        // Zoomed in, a tap off the text does nothing: no page turns, no
        // controls, so looking around never throws the page away.
        if isZoomed { return }
        guard settings.tapZones, mode != .vertical else {
            toggleChrome()
            return
        }
        if fraction < 0.3 {
            turn(forward: mode == .rightToLeft)
        } else if fraction > 0.7 {
            turn(forward: mode != .rightToLeft)
        } else {
            toggleChrome()
        }
    }

    /// Zooming in hides the controls; zooming back out restores them.
    private func zoomChanged(_ zoomed: Bool) {
        guard zoomed != isZoomed else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            if zoomed {
                chromeBeforeZoom = showChrome
                showChrome = false
            } else {
                showChrome = chromeBeforeZoom
            }
            isZoomed = zoomed
        }
    }

    private func toggleChrome() {
        if !popups.isEmpty || bubble != nil {
            popups.closeAll()
            closeBubble()
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
    }

    private func textTapped(_ page: ReaderPage, _ hit: OCRHit, _ rect: CGRect) {
        let text = texts.text(of: page)
        let point = CGPoint(x: hit.characterBox.midX, y: hit.characterBox.midY)
        let block = text?.blockIndex(at: point)
        if settings.textTap == .bubble, let block {
            openBubble(page: page, block: block)
            return
        }
        closeBubble()
        let region = block.flatMap { text?.blocks[$0].box } ?? hit.characterBox
        lookUp(SelectionData(text: hit.text, sentence: hit.sentence, rect: rect), page: page, region: region)
    }

    private func openBubble(page: ReaderPage, block: Int) {
        guard let text = texts.text(of: page), text.blocks.indices.contains(block) else { return }
        popups.closeAll()
        Haptics.play(.selection)
        bubble = OpenBubble(pageID: page.id, page: page, block: block, box: text.blocks[block].box,
                            text: text.blocks[block].text)
    }

    private func closeBubble() {
        if bubble != nil { bubble = nil }
    }

    private func lookUp(_ selection: SelectionData, bubble: OpenBubble) -> Int? {
        popups.closeAll()
        return lookUp(SelectionData(text: selection.text, sentence: bubble.text, rect: selection.rect),
                      page: bubble.page, region: bubble.box)
    }

    @discardableResult
    private func lookUp(_ selection: SelectionData, page: ReaderPage, region: CGRect) -> Int? {
        popups.coverURL = nil
        popups.documentTitle = request.title
        let picture = settings.cardPicture
        popups.mediaProvider = {
            guard let image = try? await page.load() else { return nil }
            switch picture {
            case .page:
                return CardMedia(imageURL: await MangaCardImage.page(image))
            case .bubble:
                return CardMedia(imageURL: await MangaCardImage.write(image, around: region))
            }
        }
        let matched = popups.replace(with: selection, userConfig: userConfig)
        if matched == nil {
            flash(String(localized: "辞書に見つかりませんでした"))
        }
        return matched
    }

    private func flash(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if toast == message {
                withAnimation(.easeOut(duration: 0.2)) { toast = nil }
            }
        }
    }

    private func close() {
        popups.closeAll()
        library.flush()
        onClose()
    }
}

// MARK: - Pieces

private enum ReaderSlot: Identifiable {
    /// Page indices in reading order.
    case pages([Int], id: String)
    case end(id: String)

    var id: String {
        switch self {
        case .pages(_, let id), .end(let id): id
        }
    }
}

/// The bubble whose text is open.
struct OpenBubble: Identifiable {
    var id: String { "\(pageID)#\(block)" }
    let pageID: String
    let page: ReaderPage
    let block: Int
    let box: CGRect
    let text: String
}

/// Each page's text as it's read, and which pages are being read. Kept
/// out of the reader's own state so a page finishing redraws only pages.
@Observable
final class ReaderTexts {
    private(set) var texts: [String: PageText] = [:]
    private(set) var readingIDs: Set<String> = []
    /// Pages wider than tall (already a spread), which stand alone.
    private(set) var wide: Set<String> = []
    /// Width over height of the chapter's pages (they're nearly always
    /// one size), so pages still loading in the vertical strip take the
    /// room they will need and the strip doesn't shift as they arrive.
    private(set) var typicalRatio: CGFloat?

    var reading: Int { readingIDs.count }
    /// Bumped whenever a page's text changes.
    private(set) var version = 0

    /// mokuro's text when the page has it, else what OCR found.
    func text(of page: ReaderPage) -> PageText? { page.text ?? texts[page.id] }
    func isReading(_ id: String) -> Bool { readingIDs.contains(id) }
    func isWide(_ id: String) -> Bool { wide.contains(id) }

    func startReading(_ id: String) { readingIDs.insert(id) }

    func finishReading(_ id: String, text: PageText?) {
        readingIDs.remove(id)
        if let text {
            texts[id] = text
            version += 1
        }
    }

    func remove(_ id: String) {
        texts[id] = nil
        version += 1
    }

    /// OCR's results go (mokuro's live on the pages themselves).
    func clear() {
        texts = [:]
        version += 1
    }

    func noteSize(_ size: CGSize, for id: String) {
        if size.width > size.height * 1.1, !wide.contains(id) { wide.insert(id) }
        if typicalRatio == nil, size.height > 0, size.width <= size.height * 1.1 {
            typicalRatio = size.width / size.height
        }
    }
}

/// One screen: its pages' images, loaded, with their text.
private struct ReaderSlotView: View {
    let pages: [ReaderPage]
    let rightToLeft: Bool
    let texts: ReaderTexts
    let fit: MangaPageFit
    let zoomable: Bool
    let showsBoxes: Bool
    let highlighted: OpenBubble?
    var onTap: (CGFloat) -> Void
    var onTextTap: (ReaderPage, OCRHit, CGRect) -> Void
    var onBubble: (ReaderPage, Int) -> Void
    var onZoomChange: (Bool) -> Void = { _ in }

    @State private var images: [String: UIImage] = [:]
    @State private var failed = false
    @State private var attempt = 0

    /// Left to right on screen.
    private var shown: [ReaderPage] {
        rightToLeft ? pages.reversed() : pages
    }

    var body: some View {
        Group {
            if shown.allSatisfy({ images[$0.id] != nil }) {
                let ordered = shown
                let pictures = ordered.compactMap { images[$0.id] }
                let ratio = pictures.reduce(0) { $0 + $1.size.width / max($1.size.height, 1) }
                MangaPageView(images: pictures,
                              texts: ordered.map { texts.text(of: $0) },
                              fit: fit,
                              zoomable: zoomable,
                              showsBoxes: showsBoxes,
                              highlighted: highlight(in: ordered),
                              onTap: onTap,
                              onTextTap: { index, hit, rect in onTextTap(ordered[index], hit, rect) },
                              onBubble: { index, block, _ in onBubble(ordered[index], block) },
                              onZoomChange: onZoomChange)
                    .modifier(VerticalSize(ratio: zoomable ? nil : ratio))
            } else if failed {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                    Text("画像を読み込めませんでした")
                        .font(.subheadline)
                    Button("再試行") { attempt += 1 }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(VerticalSize(ratio: zoomable ? nil : texts.typicalRatio ?? 0.7))
                .contentShape(Rectangle())
                .onTapGesture { onTap(0.5) }
            } else {
                ProgressView()
                    .tint(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(VerticalSize(ratio: zoomable ? nil : texts.typicalRatio ?? 0.7))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(0.5) }
            }
        }
        .task(id: "\(pages.map(\.id).joined(separator: "|"))#\(attempt)") {
            failed = false
            for page in pages where images[page.id] == nil {
                if let cached = MangaImages.cached(page.id) {
                    images[page.id] = cached
                    texts.noteSize(cached.size, for: page.id)
                    continue
                }
                do {
                    let image = try await page.load()
                    images[page.id] = image
                    texts.noteSize(image.size, for: page.id)
                } catch {
                    if !Task.isCancelled { failed = true }
                    return
                }
            }
        }
    }

    private func highlight(in ordered: [ReaderPage]) -> (image: Int, box: CGRect)? {
        guard let highlighted, let index = ordered.firstIndex(where: { $0.id == highlighted.pageID }) else { return nil }
        return (index, highlighted.box)
    }
}

/// In the vertical strip a page is as tall as its width makes it.
private struct VerticalSize: ViewModifier {
    let ratio: CGFloat?

    func body(content: Content) -> some View {
        if let ratio, ratio > 0 {
            content.aspectRatio(ratio, contentMode: .fit)
        } else {
            content
        }
    }
}

/// A bubble's text, for reading and tapping word by word when OCR's
/// boxes over the page are too small or slightly off.
private struct BubbleCard: View {
    let bubble: OpenBubble
    var onSelect: (SelectionData) -> Int?
    var onTapOutside: () -> Void
    var onCopy: () -> Void
    var onClose: () -> Void
    @Environment(UserConfig.self) private var userConfig

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("吹き出し")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 36, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("コピー"))
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .frame(width: 36, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("閉じる"))
                }
                .buttonStyle(.plain)
                ScrollView {
                    PostTextView(text: bubble.text,
                                 scanNonJapaneseText: userConfig.scanNonJapaneseText,
                                 style: AppearanceSettings.shared.postStyle,
                                 onTextSelected: onSelect,
                                 onTapOutside: onTapOutside,
                                 onPostReply: { _ in },
                                 onThreadRoute: { _ in })
                        .id(bubble.id)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}

/// The card's picture: the page (the default), or just the bubble with
/// some of the panel around it.
enum MangaCardImage {
    /// The whole page, large enough for its text to stay readable.
    @concurrent
    nonisolated static func page(_ image: UIImage) async -> URL? {
        CardImage.write(image, maxSide: 1400)
    }

    @concurrent
    nonisolated static func write(_ image: UIImage, around region: CGRect) async -> URL? {
        guard let cgImage = image.cgImage else { return CardImage.write(image, maxSide: 900) }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        // The bubble plus a margin as big as itself, at least about a
        // third of the page each way.
        let side = max(region.width, region.height)
        var rect = region.insetBy(dx: -side * 0.6, dy: -side * 0.6)
        if rect.width < 0.4 { rect = rect.insetBy(dx: -(0.4 - rect.width) / 2, dy: 0) }
        if rect.height < 0.3 { rect = rect.insetBy(dx: 0, dy: -(0.3 - rect.height) / 2) }
        rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = CGRect(x: rect.minX * width, y: rect.minY * height,
                            width: rect.width * width, height: rect.height * height).integral
        guard !pixels.isEmpty, let cropped = cgImage.cropping(to: pixels) else {
            return CardImage.write(image, maxSide: 900)
        }
        return CardImage.write(UIImage(cgImage: cropped), maxSide: 900)
    }
}
