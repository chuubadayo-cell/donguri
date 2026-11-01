//
//  MangaReaderSettings.swift
//  Donguri
//
//  How the manga reader shows pages and reads their text, as in Suwayomi's
//  reader (which Manatan uses): reading direction or vertical scrolling,
//  two-page spreads, how a page is fitted, tap zones, background. The
//  reading mode can be set for one title only. The Google Cloud Vision
//  key is kept in the Keychain.
//

import Foundation
import Security

enum MangaReadingMode: String, CaseIterable, Identifiable, Codable {
    case rightToLeft, leftToRight, vertical
    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightToLeft: String(localized: "右から左（マンガ）")
        case .leftToRight: String(localized: "左から右")
        case .vertical: String(localized: "縦スクロール")
        }
    }
}

enum MangaSpreadMode: String, CaseIterable, Identifiable {
    case off, landscape, always
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "使わない")
        case .landscape: String(localized: "横向きのとき")
        case .always: String(localized: "常に")
        }
    }
}

enum MangaPageFit: String, CaseIterable, Identifiable {
    case screen, width, height
    var id: String { rawValue }

    var label: String {
        switch self {
        case .screen: String(localized: "画面に合わせる")
        case .width: String(localized: "幅に合わせる")
        case .height: String(localized: "高さに合わせる")
        }
    }
}

enum MangaBackground: String, CaseIterable, Identifiable {
    case black, gray, white
    var id: String { rawValue }

    var label: String {
        switch self {
        case .black: String(localized: "黒")
        case .gray: String(localized: "グレー")
        case .white: String(localized: "白")
        }
    }
}

/// What a tap on text does; a long press does the other.
enum MangaTextTap: String, CaseIterable, Identifiable {
    case lookUp, bubble
    var id: String { rawValue }

    var label: String {
        switch self {
        case .lookUp: String(localized: "単語を調べる")
        case .bubble: String(localized: "吹き出しの文章を開く")
        }
    }
}

@Observable
final class MangaReaderSettings {
    static let shared = MangaReaderSettings()

    private let defaults = UserDefaults.standard
    private static let prefix = "iroha.manga.reader."

    var defaultMode: MangaReadingMode { didSet { save("mode", defaultMode.rawValue) } }
    var spread: MangaSpreadMode { didSet { save("spread", spread.rawValue) } }
    /// In spreads, the first page (the cover) stands alone, so pages pair
    /// up the way the printed book does.
    var coverAlone: Bool { didSet { save("coverAlone", coverAlone) } }
    var fit: MangaPageFit { didSet { save("fit", fit.rawValue) } }
    var background: MangaBackground { didSet { save("background", background.rawValue) } }
    var tapZones: Bool { didSet { save("tapZones", tapZones) } }
    var showPageNumber: Bool { didSet { save("pageNumber", showPageNumber) } }
    var keepAwake: Bool { didSet { save("keepAwake", keepAwake) } }
    /// Text is read as soon as a page appears (Manatan's way); off, only
    /// after 文字認識 is pressed.
    var autoOCR: Bool { didSet { save("autoOCR", autoOCR) } }
    var ocrEngine: MangaOCREngine { didSet { save("ocrEngine", ocrEngine.rawValue) } }
    var textTap: MangaTextTap { didSet { save("textTap", textTap.rawValue) } }
    var showTextBoxes: Bool { didSet { save("textBoxes", showTextBoxes) } }
    /// Pages read ahead of the one on screen, both their images and text.
    var preload: Int { didSet { save("preload", preload) } }

    /// Reading modes chosen for one title.
    private var modes: [String: String] { didSet { save("modes", modes) } }

    var googleAPIKey: String {
        didSet { Keychain.set(googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.googleKeyAccount) }
    }

    private static let googleKeyAccount = "iroha.manga.googleVisionKey"

    private init() {
        let d = UserDefaults.standard
        let p = Self.prefix
        defaultMode = MangaReadingMode(rawValue: d.string(forKey: p + "mode") ?? "") ?? .rightToLeft
        spread = MangaSpreadMode(rawValue: d.string(forKey: p + "spread") ?? "") ?? .landscape
        coverAlone = d.object(forKey: p + "coverAlone") as? Bool ?? true
        fit = MangaPageFit(rawValue: d.string(forKey: p + "fit") ?? "") ?? .screen
        background = MangaBackground(rawValue: d.string(forKey: p + "background") ?? "") ?? .black
        tapZones = d.object(forKey: p + "tapZones") as? Bool ?? true
        showPageNumber = d.object(forKey: p + "pageNumber") as? Bool ?? true
        keepAwake = d.object(forKey: p + "keepAwake") as? Bool ?? true
        autoOCR = d.object(forKey: p + "autoOCR") as? Bool ?? true
        ocrEngine = MangaOCREngine(rawValue: d.string(forKey: p + "ocrEngine") ?? "") ?? .vision
        textTap = MangaTextTap(rawValue: d.string(forKey: p + "textTap") ?? "") ?? .lookUp
        showTextBoxes = d.object(forKey: p + "textBoxes") as? Bool ?? false
        preload = d.object(forKey: p + "preload") as? Int ?? 3
        modes = d.dictionary(forKey: p + "modes") as? [String: String] ?? [:]
        googleAPIKey = Keychain.get(Self.googleKeyAccount) ?? ""
    }

    /// The mode for a title: its own if one was chosen, else what its
    /// source says (manga right to left, webtoons down), else the default.
    func mode(for series: String?, suggested: MangaReadingMode?) -> MangaReadingMode {
        if let series, let raw = modes[series], let mode = MangaReadingMode(rawValue: raw) { return mode }
        return suggested ?? defaultMode
    }

    func hasOwnMode(_ series: String?) -> Bool {
        series.map { modes[$0] != nil } ?? false
    }

    func setMode(_ mode: MangaReadingMode?, for series: String) {
        modes[series] = mode?.rawValue
    }

    var canUseGoogle: Bool { !googleAPIKey.isEmpty }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: Self.prefix + key)
    }
}

/// A generic password item for this app.
enum Keychain {
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
