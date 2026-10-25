//
//  PopupStack.swift
//  Donguri
//
//  The dictionary popups (Hoshi Reader's stacked model, as ThreadView uses
//  it) packaged for reuse: the gallery's OCR, the photo scanner and the
//  browser each own a PopupStack and put a PopupStackLayer over themselves.
//  Selection rects are in window coordinates; the layer ignores the safe
//  area so its space is the window's.
//

import SwiftUI

@Observable
final class PopupStack {
    var popups: [PopupItem] = []
    /// Attached to Anki cards mined from these popups (an OCR'd image, a
    /// video frame).
    var coverURL: URL?
    var documentTitle: String?
    /// Made when a card is mined from these popups; for video subtitles,
    /// the line's audio and picture.
    @ObservationIgnored var mediaProvider: (() async -> CardMedia?)?

    @ObservationIgnored private var stylesCache: [String: String]?

    var isEmpty: Bool { popups.isEmpty }

    /// Opens a popup for `selection` if the dictionaries know it. Returns
    /// how many characters matched.
    @discardableResult
    func lookUp(_ selection: SelectionData, userConfig: UserConfig, isFullWidth: Bool? = nil) -> Int? {
        let results = LookupEngine.shared.lookup(selection.text,
                                                 maxResults: userConfig.maxResults,
                                                 scanLength: userConfig.scanLength)
        guard let first = results.first else { return nil }
        let popup = PopupItem(showPopup: false,
                              currentSelection: selection,
                              lookupResults: results,
                              dictionaryStyles: styles(),
                              isVertical: false,
                              isFullWidth: isFullWidth ?? userConfig.popupFullWidth,
                              clearSelection: false)
        popups.append(popup)
        withAnimation(.default.speed(2.2)) {
            if let index = popups.firstIndex(where: { $0.id == popup.id }) {
                popups[index].showPopup = true
            }
        }
        Haptics.play(.selection)
        return first.matched.count
    }

    /// A fresh lookup: anything open closes first.
    @discardableResult
    func replace(with selection: SelectionData, userConfig: UserConfig) -> Int? {
        closeAll()
        return lookUp(selection, userConfig: userConfig)
    }

    func closeAll() {
        guard !popups.isEmpty else { return }
        let ids = Set(popups.map(\.id))
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices { popups[index].showPopup = false }
        } completion: {
            self.popups.removeAll { ids.contains($0.id) }
        }
    }

    func closeChildren(of id: UUID) {
        guard let parent = popups.firstIndex(where: { $0.id == id }) else { return }
        let ids = Set(popups.dropFirst(parent + 1).map(\.id))
        guard !ids.isEmpty else { return }
        withAnimation(.default.speed(2.4)) {
            for index in popups.indices where ids.contains(popups[index].id) {
                popups[index].showPopup = false
            }
        } completion: {
            self.popups.removeAll { ids.contains($0.id) }
        }
    }

    func swipeDismiss(_ id: UUID) {
        guard let index = popups.firstIndex(where: { $0.id == id }) else { return }
        if index == 0 {
            closeAll()
        } else {
            popups[index - 1].clearSelection.toggle()
            closeChildren(of: popups[index - 1].id)
        }
    }

    private func styles() -> [String: String] {
        if let stylesCache { return stylesCache }
        var built: [String: String] = [:]
        for style in LookupEngine.shared.getStyles() {
            built[style.dictName] = style.styles
        }
        stylesCache = built
        return built
    }
}

/// Draws a PopupStack. Put it in an overlay of the screen it belongs to.
struct PopupStackLayer: View {
    @Bindable var stack: PopupStack
    @Environment(UserConfig.self) private var userConfig

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach($stack.popups) { $popup in
                    let popupId = popup.id
                    PopupView(
                        userConfig: userConfig,
                        isVisible: $popup.showPopup,
                        selectionData: popup.currentSelection,
                        lookupResults: popup.lookupResults,
                        dictionaryStyles: popup.dictionaryStyles,
                        screenSize: geometry.size,
                        isVertical: false,
                        isFullWidth: popup.isFullWidth,
                        topInset: UIApplication.topSafeArea,
                        bottomInset: UIApplication.bottomSafeArea,
                        coverURL: stack.coverURL,
                        documentTitle: stack.documentTitle,
                        clearSelection: popup.clearSelection,
                        onTextSelected: { selection in
                            stack.closeChildren(of: popupId)
                            return stack.lookUp(selection, userConfig: userConfig, isFullWidth: false)
                        },
                        onTapOutside: {
                            stack.closeChildren(of: popupId)
                        },
                        onSwipeDismiss: {
                            stack.swipeDismiss(popupId)
                        },
                        mediaProvider: stack.mediaProvider
                    )
                    .zIndex(Double(100 + (stack.popups.firstIndex(where: { $0.id == popupId }) ?? 0)))
                }
            }
        }
        .ignoresSafeArea()
    }
}
