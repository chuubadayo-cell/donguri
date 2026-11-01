//
//  MangaReaderView.swift
//  Donguri
//
//  The manga reader: one page at a time, right to left for manga, with
//  pinch zoom and swipe down to close (the gallery's ZoomableImageView).
//  Text is tappable: mokuro's when the volume has it, else Vision's once
//  文字認識 is on. A tap opens the dictionary popups, and a card mined from
//  them gets the part of the page around the word as its picture.
//  Swiping past the last page shows the next chapter.
//

import SwiftUI

struct MangaReaderView: View {
    let request: ReaderRequest
    let onClose: () -> Void

    @Environment(UserConfig.self) private var userConfig
    @State private var library = MangaLibrary.shared
    @State private var unitIndex: Int
    @State private var pages: [ReaderPage] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var loadAttempt = 0
    @State private var currentID: String?
    @State private var showChrome = true
    @State private var isZoomed = false
    @State private var popups = PopupStack()
    @State private var recognizing = false
    @State private var toast: String?
    @State private var dismiss = ReaderDismiss()
    /// Vision reads pages that have no mokuro text.
    @AppStorage("iroha.manga.ocr") private var ocrEnabled = false
    @AppStorage("iroha.manga.textBoxes") private var showsTextBoxes = false

    init(request: ReaderRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _unitIndex = State(initialValue: request.startIndex)
    }

    private var unit: ReaderUnit? {
        request.units.indices.contains(unitIndex) ? request.units[unitIndex] : nil
    }

    private var endID: String { "\(unit?.id ?? "")#end" }

    /// Pages plus the end card, in the order they sit on screen.
    private var slots: [ReaderSlot] {
        let slots = pages.map(ReaderSlot.page) + [.end]
        return request.rightToLeft ? slots.reversed() : slots
    }

    private var currentIndex: Int? {
        pages.firstIndex { $0.id == currentID }
    }

    private var hasText: Bool {
        pages.contains { $0.text != nil }
    }

    var body: some View {
        ZStack {
            ReaderBackdrop(dismiss: dismiss)

            if isLoading {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            } else if let loadError {
                errorView(loadError)
            } else {
                pager
            }

            if showChrome {
                chrome
                    .transition(.opacity)
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
        .overlay {
            PopupStackLayer(stack: popups)
        }
        .statusBarHidden(!showChrome)
        .preferredColorScheme(.dark)
        .task(id: "\(unitIndex)#\(loadAttempt)") {
            await loadUnit()
        }
        .onChange(of: currentID) { _, id in
            isZoomed = false
            popups.closeAll()
            guard let unit, let index = pages.firstIndex(where: { $0.id == id }) else { return }
            library.setPage(index, of: pages.count, for: unit.id)
            preload(around: index)
        }
        .onDisappear {
            library.flush()
        }
        .onAppear {
            if ocrEnabled { TextRecognizer.warmUp() }
        }
    }

    // MARK: Pager

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(slots) { slot in
                    Group {
                        switch slot {
                        case .page(let page):
                            MangaReaderPage(page: page,
                                            isCurrent: page.id == currentID,
                                            ocrEnabled: ocrEnabled,
                                            showsTextBoxes: showsTextBoxes || (ocrEnabled && page.text == nil),
                                            onRecognizing: { recognizing = $0 },
                                            onTextTap: { hit, rect, image in lookUp(hit, rect: rect, image: image) },
                                            onTap: toggleChrome,
                                            onZoomChange: { isZoomed = $0 },
                                            onDismissProgress: { [dismiss] in dismiss.value = $0 },
                                            onDismiss: { close() })
                        case .end:
                            endCard
                        }
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(slot.id(end: endID))
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .scrollDisabled(isZoomed)
        .ignoresSafeArea()
        // Right to left: the first page is the rightmost.
        .defaultScrollAnchor(request.rightToLeft ? .trailing : .leading)
    }

    private var endCard: some View {
        VStack(spacing: 18) {
            if let unit {
                Text(verbatim: unit.label)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("読了")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }
            Button("閉じる") { close() }
                .buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
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
        .foregroundStyle(.white)
        .padding(32)
    }

    // MARK: Controls

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("閉じる"))

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

                if recognizing {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 44, height: 44)
                }

                Menu {
                    Toggle(isOn: $showsTextBoxes) {
                        Label("文字の枠を表示", systemImage: "rectangle.dashed")
                    }
                    if unitIndex > 0 {
                        Button {
                            unitIndex -= 1
                        } label: {
                            Label("前の章", systemImage: "chevron.backward")
                        }
                    }
                    if unitIndex + 1 < request.units.count {
                        Button {
                            unitIndex += 1
                        } label: {
                            Label("次の章", systemImage: "chevron.forward")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }

                if !hasText || !pages.allSatisfy({ $0.text != nil }) {
                    Button {
                        ocrEnabled.toggle()
                        if ocrEnabled { TextRecognizer.warmUp() }
                        flash(ocrEnabled ? String(localized: "文字認識オン") : String(localized: "文字認識オフ"))
                    } label: {
                        Image(systemName: "text.viewfinder")
                            .font(.headline)
                            .foregroundStyle(ocrEnabled ? Color.yellow : Color.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("文字認識"))
                }
            }
            .padding(.horizontal, 6)
            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top))

            Spacer()

            if let index = currentIndex {
                Text(verbatim: "\(index + 1) / \(pages.count)")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(.bottom, 8)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    // MARK: Actions

    private func loadUnit() async {
        guard let unit else { return }
        isLoading = true
        loadError = nil
        popups.closeAll()
        do {
            let loaded = try await request.pages(unit)
            guard !Task.isCancelled else { return }
            pages = loaded
            let saved = library.page(for: unit.id)
            // A finished chapter opens at its start again.
            let start = saved < loaded.count - 1 ? saved : 0
            currentID = loaded.indices.contains(start) ? loaded[start].id : loaded.first?.id
            if let mangaID = request.mangaID, let key = unit.id.split(separator: "\u{1F}").last {
                library.setLastChapter(String(key), for: mangaID)
            }
            isLoading = false
            preload(around: start)
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    /// The pages either side load ahead, so turning a page shows it at once.
    private func preload(around index: Int) {
        for offset in [1, 2, -1] {
            let neighbour = index + offset
            guard pages.indices.contains(neighbour) else { continue }
            let page = pages[neighbour]
            guard MangaImages.cached(page.id) == nil else { continue }
            Task { _ = try? await page.load() }
        }
    }

    private func toggleChrome() {
        if !popups.isEmpty {
            popups.closeAll()
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
    }

    private func lookUp(_ hit: OCRHit, rect: CGRect, image: UIImage) {
        popups.coverURL = nil
        popups.documentTitle = request.title
        let box = hit.characterBox
        popups.mediaProvider = {
            CardMedia(imageURL: await MangaCardImage.write(image, around: box))
        }
        let selection = SelectionData(text: hit.text, sentence: hit.sentence, rect: rect)
        if popups.replace(with: selection, userConfig: userConfig) == nil {
            flash(String(localized: "辞書に見つかりませんでした"))
        }
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

private enum ReaderSlot: Identifiable {
    case page(ReaderPage)
    case end

    var id: String { id(end: "end") }

    func id(end: String) -> String {
        switch self {
        case .page(let page): page.id
        case .end: end
        }
    }
}

/// One page: loads its image, reads its text if asked.
private struct MangaReaderPage: View {
    let page: ReaderPage
    let isCurrent: Bool
    let ocrEnabled: Bool
    let showsTextBoxes: Bool
    var onRecognizing: (Bool) -> Void
    var onTextTap: (OCRHit, CGRect, UIImage) -> Void
    var onTap: () -> Void
    var onZoomChange: (Bool) -> Void
    var onDismissProgress: (CGFloat) -> Void
    var onDismiss: () -> Void

    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    @State private var recognized: [OCRLine]?

    private var lines: [OCRLine]? {
        page.text ?? (ocrEnabled ? recognized : nil)
    }

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image,
                                  onTap: onTap,
                                  onZoomChange: onZoomChange,
                                  onDismissProgress: onDismissProgress,
                                  onDismiss: { _ in onDismiss(); return false },
                                  ocrLines: lines,
                                  showsTextBoxes: showsTextBoxes,
                                  onTextTap: { hit, rect in onTextTap(hit, rect, image) })
                    .task(id: ocrEnabled && isCurrent) {
                        await recognizeIfNeeded(image)
                    }
            } else if failed {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                    Text("画像を読み込めませんでした")
                        .font(.subheadline)
                    Button("再試行") { attempt += 1 }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            }
        }
        .task(id: "\(page.id)#\(attempt)") {
            if image != nil { return }
            failed = false
            if let cached = MangaImages.cached(page.id) {
                image = cached
                return
            }
            do {
                image = try await page.load()
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    private func recognizeIfNeeded(_ image: UIImage) async {
        guard ocrEnabled, isCurrent, page.text == nil, recognized == nil else { return }
        if let cached = OCRCache.lines(for: page.id) {
            recognized = cached
            return
        }
        onRecognizing(true)
        let lines = await OCRCache.recognize(image, id: page.id)
        onRecognizing(false)
        recognized = lines
    }
}

/// How far a swipe-to-close has gone, read only by the backdrop.
@Observable
private final class ReaderDismiss {
    var value: CGFloat = 0
}

private struct ReaderBackdrop: View {
    let dismiss: ReaderDismiss

    var body: some View {
        Color.black
            .opacity(1 - dismiss.value * 0.85)
            .ignoresSafeArea()
    }
}

/// The card's picture: the part of the page around the looked-up word
/// (the panel it's in, roughly), not the whole page, whose text would be
/// too small to read on a card.
enum MangaCardImage {
    @concurrent
    nonisolated static func write(_ image: UIImage, around box: CGRect) async -> URL? {
        guard let cgImage = image.cgImage else { return CardImage.write(image, maxSide: 900) }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let cropWidth = width * 0.62
        let cropHeight = min(height, cropWidth * 1.15)
        let x = min(max(box.midX * width - cropWidth / 2, 0), width - cropWidth)
        let y = min(max(box.midY * height - cropHeight / 2, 0), height - cropHeight)
        let rect = CGRect(x: x, y: y, width: cropWidth, height: cropHeight).integral
        guard let cropped = cgImage.cropping(to: rect) else { return CardImage.write(image, maxSide: 900) }
        return CardImage.write(UIImage(cgImage: cropped), maxSide: 900)
    }
}
