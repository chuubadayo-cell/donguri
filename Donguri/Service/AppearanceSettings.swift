//
//  AppearanceSettings.swift
//  Donguri
//
//  外観: how the app looks. Three kinds of text are styled independently,
//  because they're read differently:
//   - UI text (menus, lists, buttons): a system design and a size, applied
//     app-wide through SwiftUI's environment so every screen follows.
//   - Post text (what you read in threads): any installed font, size and
//     line spacing, plus its colours.
//   - Dictionary text (the lookup popup): any installed font, injected into
//     the popup's stylesheet. Its size is the popup's existing 拡大率.
//  Backed by UserDefaults.
//

import SwiftUI
import UIKit

@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: String(localized: "システムに合わせる")
            case .light: String(localized: "ライト")
            case .dark: String(localized: "ダーク")
            }
        }
    }

    enum UIDesign: String, CaseIterable, Identifiable {
        case standard, rounded, serif, monospaced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: String(localized: "標準")
            case .rounded: String(localized: "丸ゴシック")
            case .serif: String(localized: "明朝（セリフ）")
            case .monospaced: String(localized: "等幅")
            }
        }
        var design: Font.Design {
            switch self {
            case .standard: .default
            case .rounded: .rounded
            case .serif: .serif
            case .monospaced: .monospaced
            }
        }
    }

    /// UI text sizes on offer, smallest first. Index -1 follows the system
    /// text size setting.
    static let uiTextSizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]

    private static let prefix = "donguri.appearance."

    // MARK: UI

    var theme: Theme { didSet { save(theme.rawValue, "theme") } }
    var uiDesign: UIDesign { didSet { save(uiDesign.rawValue, "uiDesign") } }
    var uiTextSizeIndex: Int { didSet { save(uiTextSizeIndex, "uiTextSizeIndex") } }
    var accentColorHex: String? { didSet { save(accentColorHex, "accentColor") } }

    // MARK: Posts

    /// Empty means the system font.
    var postFontFamily: String { didSet { save(postFontFamily, "postFontFamily") } }
    var postFontSize: Double { didSet { save(postFontSize, "postFontSize") } }
    var postLineSpacing: Double { didSet { save(postLineSpacing, "postLineSpacing") } }
    var postTextColorHex: String? { didSet { save(postTextColorHex, "postTextColor") } }
    var linkColorHex: String? { didSet { save(linkColorHex, "linkColor") } }
    var highlightColorHex: String? { didSet { save(highlightColorHex, "highlightColor") } }
    var threadBackgroundHex: String? { didSet { save(threadBackgroundHex, "threadBackground") } }

    // MARK: Dictionary

    /// Empty means the popup's own default (Hiragino Sans).
    var dictionaryFontFamily: String { didSet { save(dictionaryFontFamily, "dictionaryFontFamily") } }

    static let defaultPostFontSize: Double = 17
    static let defaultPostLineSpacing: Double = 1.45
    static let defaultLinkColor = UIColor(red: 66 / 255, green: 108 / 255, blue: 245 / 255, alpha: 1)
    static let defaultHighlightColor = UIColor(white: 0.63, alpha: 0.4)

    private init() {
        let d = UserDefaults.standard
        let p = Self.prefix
        theme = d.string(forKey: p + "theme").flatMap(Theme.init(rawValue:)) ?? .system
        uiDesign = d.string(forKey: p + "uiDesign").flatMap(UIDesign.init(rawValue:)) ?? .standard
        uiTextSizeIndex = d.object(forKey: p + "uiTextSizeIndex") as? Int ?? -1
        accentColorHex = d.string(forKey: p + "accentColor")
        postFontFamily = d.string(forKey: p + "postFontFamily") ?? ""
        postFontSize = d.object(forKey: p + "postFontSize") as? Double ?? Self.defaultPostFontSize
        postLineSpacing = d.object(forKey: p + "postLineSpacing") as? Double ?? Self.defaultPostLineSpacing
        postTextColorHex = d.string(forKey: p + "postTextColor")
        linkColorHex = d.string(forKey: p + "linkColor")
        highlightColorHex = d.string(forKey: p + "highlightColor")
        threadBackgroundHex = d.string(forKey: p + "threadBackground")
        dictionaryFontFamily = d.string(forKey: p + "dictionaryFontFamily") ?? ""
    }

    func resetAll() {
        theme = .system
        uiDesign = .standard
        uiTextSizeIndex = -1
        accentColorHex = nil
        postFontFamily = ""
        postFontSize = Self.defaultPostFontSize
        postLineSpacing = Self.defaultPostLineSpacing
        postTextColorHex = nil
        linkColorHex = nil
        highlightColorHex = nil
        threadBackgroundHex = nil
        dictionaryFontFamily = ""
    }

    private func save(_ value: Any?, _ key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: Self.prefix + key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.prefix + key)
        }
    }

    // MARK: Derived values

    var colorScheme: ColorScheme? {
        switch theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var accentColor: Color? {
        accentColorHex.flatMap(UIColor.init(hex:)).map(Color.init(uiColor:))
    }

    var dynamicTypeSize: DynamicTypeSize? {
        Self.uiTextSizes.indices.contains(uiTextSizeIndex) ? Self.uiTextSizes[uiTextSizeIndex] : nil
    }

    var threadBackground: Color? {
        threadBackgroundHex.flatMap(UIColor.init(hex:)).map(Color.init(uiColor:))
    }

    /// Everything post rendering needs, as one value: reading it in a view's
    /// body is what makes posts redraw when a setting changes.
    var postStyle: PostTextStyle {
        PostTextStyle(fontFamily: postFontFamily,
                      fontSize: CGFloat(postFontSize),
                      lineSpacing: CGFloat(postLineSpacing),
                      textColor: postTextColorHex.flatMap(UIColor.init(hex:)) ?? .label,
                      linkColor: linkColorHex.flatMap(UIColor.init(hex:)) ?? Self.defaultLinkColor,
                      highlightColor: highlightColorHex.flatMap(UIColor.init(hex:)) ?? Self.defaultHighlightColor,
                      key: [postFontFamily, "\(postFontSize)", "\(postLineSpacing)",
                            postTextColorHex ?? "-", linkColorHex ?? "-"].joined(separator: "|"))
    }

    /// Prepended to the popup's custom CSS. `body *` matches the specificity
    /// of popup.css's own `!important` font rule and comes later, so it wins.
    var dictionaryCSS: String {
        let family = dictionaryFontFamily.replacingOccurrences(of: "\"", with: "")
        guard !family.isEmpty else { return "" }
        return "html, body, body * { font-family: \"\(family)\", \"Hiragino Sans\", sans-serif !important; }\n"
    }

    // MARK: Fonts

    /// Japanese-capable families iOS ships or can download, in a sensible
    /// order. Only the installed ones are offered.
    private static let japaneseFamilies = [
        "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Hiragino Mincho ProN", "Hiragino Maru Gothic ProN",
        "Klee", "Tsukushi A Round Gothic", "Tsukushi B Round Gothic",
        "Toppan Bunkyu Gothic", "Toppan Bunkyu Midashi Gothic", "Toppan Bunkyu Mincho", "Toppan Bunkyu Midashi Mincho",
        "YuKyokasho", "YuKyokasho Yoko", "YuMincho", "YuGothic", "BIZ UDGothic", "BIZ UDMincho",
    ]

    static var installedJapaneseFamilies: [String] {
        let installed = Set(UIFont.familyNames)
        return japaneseFamilies.filter { installed.contains($0) }
    }

    static var otherInstalledFamilies: [String] {
        let japanese = Set(japaneseFamilies)
        return UIFont.familyNames.filter { !japanese.contains($0) }.sorted()
    }
}

/// How post text is drawn. `key` identifies the combination for caching.
struct PostTextStyle {
    var fontFamily: String
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var textColor: UIColor
    var linkColor: UIColor
    var highlightColor: UIColor
    var key: String

    var font: UIFont {
        PostTextStyle.font(family: fontFamily, size: fontSize)
    }

    static func font(family: String, size: CGFloat) -> UIFont {
        guard !family.isEmpty else { return .systemFont(ofSize: size) }
        let descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        let font = UIFont(descriptor: descriptor, size: size)
        // An uninstalled family silently falls back to something unrelated.
        return font.familyName == family ? font : .systemFont(ofSize: size)
    }
}

extension UIColor {
    /// `#RRGGBB` or `#RRGGBBAA`.
    convenience init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6 || string.count == 8, let value = UInt64(string, radix: 16) else { return nil }
        let hasAlpha = string.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(r), byte(g), byte(b), byte(a))
    }
}
