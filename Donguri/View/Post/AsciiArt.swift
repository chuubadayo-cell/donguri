//
//  AsciiArt.swift
//  Donguri
//
//  5ch's ASCII art (AA) is drawn with spaces and symbols lined up for one
//  font: MS P Gothic at 16px. In any other font it falls apart. Saitamaar
//  (by keage, made for showing AA) has the same character widths, so posts
//  that look like AA are drawn in it, without wrapping, scaled down until
//  the widest line fits the screen.
//

import UIKit
import CoreText

enum AsciiArt {
    static let fontName = "Saitamaar"
    /// The size AA is made for; widths are measured at this size.
    static let designSize: CGFloat = 16
    /// Below this it's unreadable anyway.
    static let minimumSize: CGFloat = 4

    /// Makes the bundled font available. Call once at launch.
    static func registerFont() {
        guard UIFont(name: fontName, size: 12) == nil,
              let url = Bundle.main.url(forResource: fontName, withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func font(size: CGFloat) -> UIFont {
        UIFont(name: fontName, size: size) ?? .systemFont(ofSize: size)
    }

    private static let detectionCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 4000
        return cache
    }()

    private static let widthCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 1000
        return cache
    }()

    /// Characters AA is built from (and ordinary prose rarely uses in bulk).
    private static let artCharacters = Set(
        "´｀`ﾟ゜∀ДдΦφθ⊂⊃∪∩彡ミ⌒ノヽ丶ﾉﾍﾚﾊ／＼/\\|｜￣＿_─━│┃┏┓┗┛┠┨┼＿○◯◎●从ゝ∧∨Λ＜＞<>ω≡＝=‐-‥…:：;；,，.．、'’\"”ｨｲｭｯｰ~〜ˇ¨＾^〃⌒⊿∠∵∴ⅰⅱ（）()[]{}＼"
    )

    /// True if the post looks like ASCII art: several lines that are
    /// mostly symbols, or lined up with runs of spaces. Takes the post text
    /// as PostService stores it (with `[label](url)` links).
    static func isArt(_ text: String) -> Bool {
        guard text.contains("\n") else { return false }
        let key = text as NSString
        if let cached = detectionCache.object(forKey: key) { return cached.boolValue }
        let result = detect(text.asPlainPostText)
        detectionCache.setObject(NSNumber(value: result), forKey: key)
        return result
    }

    private static func detect(_ text: String) -> Bool {
        guard text.count >= 30, text.contains("\n") else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 4 else { return false }

        var artLines = 0
        var symbolCount = 0
        var totalCount = 0
        for line in lines {
            var symbols = 0
            var count = 0
            var spaceRun = 0
            var longestSpaceRun = 0
            for character in line {
                count += 1
                if character == " " || character == "\u{3000}" {
                    spaceRun += character == "\u{3000}" ? 2 : 1
                    longestSpaceRun = max(longestSpaceRun, spaceRun)
                    continue
                }
                spaceRun = 0
                if artCharacters.contains(character) || isHalfwidthKatakana(character) {
                    symbols += 1
                }
            }
            symbolCount += symbols
            totalCount += count
            let symbolRatio = count > 0 ? Double(symbols) / Double(count) : 0
            if longestSpaceRun >= 3 || (symbols >= 3 && symbolRatio >= 0.3) {
                artLines += 1
            }
        }
        guard totalCount > 0 else { return false }
        let overallRatio = Double(symbolCount) / Double(totalCount)
        return artLines >= 3 && Double(artLines) / Double(lines.count) >= 0.45 && overallRatio >= 0.12
    }

    private static func isHalfwidthKatakana(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0xFF61...0xFF9F).contains(scalar.value)
    }

    /// Width of the widest line at the design size, as displayed.
    static func widestLine(_ text: String) -> CGFloat {
        let key = text as NSString
        if let cached = widthCache.object(forKey: key) { return CGFloat(cached.doubleValue) }
        let measuringFont = Self.font(size: designSize)
        var widest: CGFloat = 0
        for line in text.asPlainPostText.split(separator: "\n", omittingEmptySubsequences: false) {
            let width = NSAttributedString(string: String(line), attributes: [.font: measuringFont]).size().width
            widest = max(widest, width)
        }
        widthCache.setObject(NSNumber(value: Double(widest)), forKey: key)
        return widest
    }

    /// The font size at which the post's text fits `width`.
    static func fittingSize(for text: String, width: CGFloat, maximum: CGFloat) -> CGFloat {
        let widest = widestLine(text)
        guard widest > 0, width > 0 else { return min(maximum, designSize) }
        // A little slack so rounding never clips the last character.
        let size = designSize * (width - 2) / widest
        return max(minimumSize, min(maximum, designSize, size)).rounded(.down, toNearest: 0.25)
    }
}

private extension CGFloat {
    func rounded(_ rule: FloatingPointRoundingRule, toNearest step: CGFloat) -> CGFloat {
        (self / step).rounded(rule) * step
    }
}
