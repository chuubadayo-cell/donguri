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

    /// The themes that ship with the app. Custom themes are added in the
    /// theme editor and identified as `custom:<uuid>`.
    enum BuiltInTheme: String, CaseIterable, Identifiable {
        case system, light, dark, sepia, darkSepia, futaba, navy, oled
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: String(localized: "システムに合わせる")
            case .light: String(localized: "ライト")
            case .dark: String(localized: "ダーク")
            case .sepia: String(localized: "セピア")
            case .darkSepia: String(localized: "ダークセピア")
            case .futaba: String(localized: "ふたば")
            case .navy: String(localized: "ネイビー")
            case .oled: String(localized: "ブラック（有機EL）")
            }
        }

        /// Themes that recolour the reading screens rather than using the
        /// system's own light or dark colours.
        var palette: ThemePalette? {
            switch self {
            case .system, .light, .dark: nil
            case .sepia: .sepia
            case .darkSepia: .darkSepia
            case .futaba: .futaba
            case .navy: .navy
            case .oled: .oled
            }
        }

        var fixedScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            default: palette.map { $0.isDark ? .dark : .light }
            }
        }
    }

    /// One theme on offer, built in or custom, for pickers.
    struct ThemeOption: Identifiable, Hashable {
        let id: String
        let title: String
        /// Swatch colours, nil for the system colour themes.
        let palette: ThemePalette?
        let isDark: Bool?
    }

    enum Density: String, CaseIterable, Identifiable {
        case compact, standard, comfortable
        var id: String { rawValue }
        var title: String {
            switch self {
            case .compact: String(localized: "コンパクト")
            case .standard: String(localized: "標準")
            case .comfortable: String(localized: "ゆったり")
            }
        }
        /// Vertical padding of a post row.
        var rowPadding: CGFloat {
            switch self {
            case .compact: 2
            case .standard: 6
            case .comfortable: 11
            }
        }
        /// Space between a post's header, body and footer.
        var spacing: CGFloat {
            switch self {
            case .compact: 3
            case .standard: 6
            case .comfortable: 9
            }
        }
    }

    enum ThumbnailSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: String(localized: "小")
            case .medium: String(localized: "中")
            case .large: String(localized: "大")
            }
        }
        var side: CGFloat {
            switch self {
            case .small: 54
            case .medium: 72
            case .large: 96
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

    /// A built-in theme's raw value or `custom:<uuid>`.
    var themeID: String { didSet { save(themeID, "theme"); resolveTheme() } }
    /// Follow the system's light/dark mode, with a theme for each.
    var autoTheme: Bool { didSet { save(autoTheme, "autoTheme"); resolveTheme() } }
    var lightThemeID: String { didSet { save(lightThemeID, "lightTheme"); resolveTheme() } }
    var darkThemeID: String { didSet { save(darkThemeID, "darkTheme"); resolveTheme() } }
    private(set) var customThemes: [CustomTheme] { didSet { saveCustomThemes(); resolveTheme() } }
    /// Set from the root view's colour scheme, for the automatic theme.
    var systemIsDark = false { didSet { if oldValue != systemIsDark, autoTheme { resolveTheme() } } }

    /// The palette in use (the sepia themes, the other coloured themes and
    /// custom ones), worked out once whenever the theme changes rather than
    /// on every read: post rows read it constantly.
    private(set) var palette: ThemePalette?
    /// The id of the theme on screen right now.
    private(set) var activeThemeID: String = BuiltInTheme.system.rawValue
    /// The palette's colours as a string, so an edited custom theme
    /// invalidates cached post text.
    private(set) var paletteSignature = "-"
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

    // MARK: Thread layout

    /// Hide the board's default name (名無しさん, 風吹けば名無し …) the way
    /// Chance hides default usernames; only real names and tripcodes show.
    var hideDefaultNames: Bool { didSet { save(hideDefaultNames, "hideDefaultNames") } }
    /// "5分前" next to each post's time.
    var showRelativeTime: Bool { didSet { save(showRelativeTime, "showRelativeTime") } }
    var density: Density { didSet { save(density.rawValue, "density") } }
    var thumbnailSize: ThumbnailSize { didSet { save(thumbnailSize.rawValue, "thumbnailSize") } }
    /// Thumbnails beside the text on the right instead of the left.
    var thumbnailOnRight: Bool { didSet { save(thumbnailOnRight, "thumbnailOnRight") } }
    /// Lines between posts.
    var postSeparators: Bool { didSet { save(postSeparators, "postSeparators") } }
    /// Detect ASCII art and draw it in an MS P Gothic–compatible font,
    /// scaled to fit the screen, so it lines up.
    var asciiArtFont: Bool { didSet { save(asciiArtFont, "asciiArtFont") } }

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
        themeID = d.string(forKey: p + "theme") ?? BuiltInTheme.system.rawValue
        autoTheme = d.object(forKey: p + "autoTheme") as? Bool ?? false
        lightThemeID = d.string(forKey: p + "lightTheme") ?? BuiltInTheme.light.rawValue
        darkThemeID = d.string(forKey: p + "darkTheme") ?? BuiltInTheme.dark.rawValue
        if let data = d.data(forKey: p + "customThemes"),
           let decoded = try? JSONDecoder().decode([CustomTheme].self, from: data) {
            customThemes = decoded
        } else {
            customThemes = []
        }
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
        hideDefaultNames = d.object(forKey: p + "hideDefaultNames") as? Bool ?? true
        showRelativeTime = d.object(forKey: p + "showRelativeTime") as? Bool ?? true
        density = d.string(forKey: p + "density").flatMap(Density.init(rawValue:)) ?? .standard
        thumbnailSize = d.string(forKey: p + "thumbnailSize").flatMap(ThumbnailSize.init(rawValue:)) ?? .medium
        thumbnailOnRight = d.object(forKey: p + "thumbnailOnRight") as? Bool ?? false
        postSeparators = d.object(forKey: p + "postSeparators") as? Bool ?? true
        asciiArtFont = d.object(forKey: p + "asciiArtFont") as? Bool ?? true
        systemIsDark = UIScreen.main.traitCollection.userInterfaceStyle == .dark
        resolveTheme()
    }

    func resetAll() {
        themeID = BuiltInTheme.system.rawValue
        autoTheme = false
        lightThemeID = BuiltInTheme.light.rawValue
        darkThemeID = BuiltInTheme.dark.rawValue
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
        hideDefaultNames = true
        showRelativeTime = true
        density = .standard
        thumbnailSize = .medium
        thumbnailOnRight = false
        postSeparators = true
        asciiArtFont = true
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
        // The automatic theme leaves light and dark to the system.
        if autoTheme { return nil }
        if let builtIn = BuiltInTheme(rawValue: themeID) { return builtIn.fixedScheme }
        return palette.map { $0.isDark ? .dark : .light }
    }

    // MARK: Themes

    static let customPrefix = "custom:"

    var themeOptions: [ThemeOption] {
        BuiltInTheme.allCases.map {
            ThemeOption(id: $0.rawValue, title: $0.title, palette: $0.palette, isDark: $0.fixedScheme.map { $0 == .dark })
        } + customThemes.map {
            ThemeOption(id: Self.customPrefix + $0.id.uuidString, title: $0.name, palette: $0.palette, isDark: $0.isDark)
        }
    }

    func title(forTheme id: String) -> String {
        themeOptions.first { $0.id == id }?.title ?? BuiltInTheme.system.title
    }

    func palette(forTheme id: String) -> ThemePalette? {
        if let builtIn = BuiltInTheme(rawValue: id) { return builtIn.palette }
        return customTheme(id: id)?.palette
    }

    func customTheme(id: String) -> CustomTheme? {
        guard id.hasPrefix(Self.customPrefix),
              let uuid = UUID(uuidString: String(id.dropFirst(Self.customPrefix.count))) else { return nil }
        return customThemes.first { $0.id == uuid }
    }

    /// Adds or replaces a custom theme.
    func saveCustomTheme(_ theme: CustomTheme) {
        if let index = customThemes.firstIndex(where: { $0.id == theme.id }) {
            customThemes[index] = theme
        } else {
            customThemes.append(theme)
        }
    }

    func deleteCustomTheme(_ theme: CustomTheme) {
        let id = Self.customPrefix + theme.id.uuidString
        customThemes.removeAll { $0.id == theme.id }
        if themeID == id { themeID = BuiltInTheme.system.rawValue }
        if lightThemeID == id { lightThemeID = BuiltInTheme.light.rawValue }
        if darkThemeID == id { darkThemeID = BuiltInTheme.dark.rawValue }
    }

    private func resolveTheme() {
        let id = autoTheme ? (systemIsDark ? darkThemeID : lightThemeID) : themeID
        activeThemeID = id
        palette = palette(forTheme: id)
        paletteSignature = palette?.signature ?? "-"
    }

    private func saveCustomThemes() {
        guard let data = try? JSONEncoder().encode(customThemes) else { return }
        UserDefaults.standard.set(data, forKey: Self.prefix + "customThemes")
    }

    var accentColor: Color? {
        if let custom = accentColorHex.flatMap(UIColor.init(hex:)) { return Color(uiColor: custom) }
        return palette.map { Color(uiColor: $0.accent) }
    }

    var dynamicTypeSize: DynamicTypeSize? {
        Self.uiTextSizes.indices.contains(uiTextSizeIndex) ? Self.uiTextSizes[uiTextSizeIndex] : nil
    }

    var threadBackground: Color? {
        if let custom = threadBackgroundHex.flatMap(UIColor.init(hex:)) { return Color(uiColor: custom) }
        return palette.map { Color(uiColor: $0.background) }
    }

    /// Everything post rendering needs, as one value: reading it in a view's
    /// body is what makes posts redraw when a setting changes.
    var postStyle: PostTextStyle {
        PostTextStyle(fontFamily: postFontFamily,
                      fontSize: CGFloat(postFontSize),
                      lineSpacing: CGFloat(postLineSpacing),
                      textColor: postTextColorHex.flatMap(UIColor.init(hex:)) ?? palette?.text ?? .label,
                      linkColor: linkColorHex.flatMap(UIColor.init(hex:)) ?? palette?.link ?? Self.defaultLinkColor,
                      highlightColor: highlightColorHex.flatMap(UIColor.init(hex:)) ?? Self.defaultHighlightColor,
                      detectsAsciiArt: asciiArtFont,
                      key: [asciiArtFont ? "aa" : "-", postFontFamily, "\(postFontSize)", "\(postLineSpacing)",
                            postTextColorHex ?? "-", linkColorHex ?? "-", highlightColorHex ?? "-",
                            activeThemeID, paletteSignature].joined(separator: "|"))
    }

    /// Prepended to the popup's custom CSS. `body *` matches the specificity
    /// of popup.css's own `!important` font rule and comes later, so it wins.
    var dictionaryCSS: String {
        var css = ""
        let family = dictionaryFontFamily.replacingOccurrences(of: "\"", with: "")
        if !family.isEmpty {
            css += "html, body, body * { font-family: \"\(family)\", \"Hiragino Sans\", sans-serif !important; }\n"
        }
        if let palette {
            // popup.css reads its text colour from --text-color.
            css += "html, body { --text-color: \(palette.text.hexString.cssColor) !important; color: \(palette.text.hexString.cssColor) !important; }\n"
        }
        return css
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
    /// Draw posts that look like ASCII art in the AA font (see AsciiArt).
    var detectsAsciiArt: Bool = false
    var key: String
    /// False for ASCII art, whose lines must never wrap.
    var wraps: Bool = true

    /// This style for ASCII art at `size`.
    func asciiArt(size: CGFloat) -> PostTextStyle {
        var style = self
        style.fontFamily = AsciiArt.fontName
        style.fontSize = size
        style.lineSpacing = 1.0
        style.wraps = false
        style.detectsAsciiArt = false
        style.key = key + "|aa|\(size)"
        return style
    }

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

/// A theme's colours, modelled on Chance's themes: a page background, a
/// slightly different "bar" colour for bars and cards, text, secondary
/// text, an accent, links, and a title colour for thread titles.
struct ThemePalette: Hashable {
    let background: UIColor
    let bar: UIColor
    let text: UIColor
    let secondaryText: UIColor
    let accent: UIColor
    let link: UIColor
    let title: UIColor
    /// Dark themes put the system in dark mode, for its controls.
    var isDark: Bool = false

    /// Identifies the colours, for caches keyed on how text is drawn.
    var signature: String {
        [background, bar, text, secondaryText, accent, link, title].map(\.hexString).joined()
    }

    static let sepia = ThemePalette(
        background: UIColor(hex: "#F4ECD8")!,
        bar: UIColor(hex: "#EADFC5")!,
        text: UIColor(hex: "#4B3A2A")!,
        secondaryText: UIColor(hex: "#8A7458")!,
        accent: UIColor(hex: "#A0522D")!,
        link: UIColor(hex: "#9C4A1C")!,
        title: UIColor(hex: "#6B7A2E")!
    )

    static let darkSepia = ThemePalette(
        background: UIColor(hex: "#221D18")!,
        bar: UIColor(hex: "#2F2822")!,
        text: UIColor(hex: "#E3D5BC")!,
        secondaryText: UIColor(hex: "#A2927A")!,
        accent: UIColor(hex: "#D9935B")!,
        link: UIColor(hex: "#E0A06A")!,
        title: UIColor(hex: "#B5C27A")!,
        isDark: true
    )

    /// The classic imageboard look: cream page, maroon text.
    static let futaba = ThemePalette(
        background: UIColor(hex: "#FFFFEE")!,
        bar: UIColor(hex: "#F0E0D6")!,
        text: UIColor(hex: "#800000")!,
        secondaryText: UIColor(hex: "#A06A5A")!,
        accent: UIColor(hex: "#CC1105")!,
        link: UIColor(hex: "#0F4FC0")!,
        title: UIColor(hex: "#117743")!
    )

    static let navy = ThemePalette(
        background: UIColor(hex: "#1B2333")!,
        bar: UIColor(hex: "#232D40")!,
        text: UIColor(hex: "#DCE3EE")!,
        secondaryText: UIColor(hex: "#8B98AD")!,
        accent: UIColor(hex: "#6CA6FF")!,
        link: UIColor(hex: "#7FB2FF")!,
        title: UIColor(hex: "#A8D08D")!,
        isDark: true
    )

    /// True black, which an OLED screen doesn't light at all.
    static let oled = ThemePalette(
        background: UIColor(hex: "#000000")!,
        bar: UIColor(hex: "#101010")!,
        text: UIColor(hex: "#E6E6E6")!,
        secondaryText: UIColor(hex: "#8A8A8A")!,
        accent: UIColor(hex: "#5E9EFF")!,
        link: UIColor(hex: "#6FA8FF")!,
        title: UIColor(hex: "#9CC97A")!,
        isDark: true
    )
}

/// A theme made in the theme editor. Colours are stored as hex strings.
struct CustomTheme: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var isDark: Bool
    var background: String
    var bar: String
    var text: String
    var secondaryText: String
    var accent: String
    var link: String
    var title: String

    var palette: ThemePalette {
        func color(_ hex: String, _ fallback: UIColor) -> UIColor { UIColor(hex: hex) ?? fallback }
        return ThemePalette(background: color(background, .systemBackground),
                            bar: color(bar, .secondarySystemBackground),
                            text: color(text, .label),
                            secondaryText: color(secondaryText, .secondaryLabel),
                            accent: color(accent, .systemBlue),
                            link: color(link, .link),
                            title: color(title, .label),
                            isDark: isDark)
    }

    /// A new theme starting from another theme's colours (or the system's,
    /// resolved for light or dark).
    init(name: String, from palette: ThemePalette?, isDark: Bool) {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        func hex(_ color: UIColor) -> String { color.resolvedColor(with: traits).hexString }
        let base = palette ?? ThemePalette(background: .systemBackground,
                                           bar: .secondarySystemBackground,
                                           text: .label,
                                           secondaryText: .secondaryLabel,
                                           accent: UIColor(named: "AccentColor") ?? .systemBlue,
                                           link: AppearanceSettings.defaultLinkColor,
                                           title: .label,
                                           isDark: isDark)
        self.name = name
        self.isDark = palette?.isDark ?? isDark
        background = hex(base.background)
        bar = hex(base.bar)
        text = hex(base.text)
        secondaryText = hex(base.secondaryText)
        accent = hex(base.accent)
        link = hex(base.link)
        title = hex(base.title)
    }
}

private extension String {
    /// `#RRGGBBAA` → `#RRGGBB`; CSS reads 8-digit hex too, but not every
    /// WebKit build has.
    var cssColor: String { count == 9 ? String(prefix(7)) : self }
}
