//
//  AppearanceView.swift
//  Donguri
//
//  外観 settings: theme and colours, UI text, post text and dictionary text.
//

import SwiftUI
import UIKit

struct AppearanceView: View {
    @State private var appearance = AppearanceSettings.shared
    @Environment(UserConfig.self) private var userConfig
    @State private var confirmReset = false

    var body: some View {
        @Bindable var userConfig = self.userConfig

        List {
            Section {
                Toggle("ライト/ダークで自動切り替え", isOn: $appearance.autoTheme)
                if appearance.autoTheme {
                    themeLink(title: String(localized: "ライト時のテーマ"), selection: $appearance.lightThemeID)
                    themeLink(title: String(localized: "ダーク時のテーマ"), selection: $appearance.darkThemeID)
                } else {
                    themeLink(title: String(localized: "テーマ"), selection: $appearance.themeID)
                }
                ColorSettingRow(title: "アクセントカラー", hex: $appearance.accentColorHex,
                                defaultColor: UIColor(named: "AccentColor") ?? .systemBlue)
            } header: {
                Text("テーマと色")
            } footer: {
                Text("自動切り替えでは、iPhoneのライト/ダークモードに合わせてテーマが切り替わります。テーマの画面から自分のテーマも作れます。")
            }

            Section {
                Picker("書体", selection: $appearance.uiDesign) {
                    ForEach(AppearanceSettings.UIDesign.allCases) { design in
                        Text(design.title).tag(design)
                    }
                }
                Picker("文字の大きさ", selection: $appearance.uiTextSizeIndex) {
                    Text("システムに合わせる").tag(-1)
                    ForEach(AppearanceSettings.uiTextSizes.indices, id: \.self) { index in
                        Text(Self.sizeLabel(index)).tag(index)
                    }
                }
            } header: {
                Text("UIの文字")
            } footer: {
                Text("メニュー、一覧、ボタンなどの文字です。")
            }

            Section {
                NavigationLink {
                    FontPickerView(title: String(localized: "書き込みのフォント"),
                                   selection: $appearance.postFontFamily,
                                   defaultLabel: String(localized: "システム（標準）"))
                } label: {
                    LabeledContent("フォント", value: fontLabel(appearance.postFontFamily,
                                                            default: String(localized: "システム（標準）")))
                }
                LabeledContent {
                    Stepper(value: $appearance.postFontSize, in: 11...32, step: 1) {
                        Text(verbatim: "\(Int(appearance.postFontSize)) pt")
                            .monospacedDigit()
                    }
                } label: {
                    Text("大きさ")
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("行間")
                        Spacer()
                        Text(verbatim: String(format: "%.2f", appearance.postLineSpacing))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $appearance.postLineSpacing, in: 1.0...2.2, step: 0.05)
                }
                ColorSettingRow(title: "文字の色", hex: $appearance.postTextColorHex, defaultColor: .label)
                ColorSettingRow(title: "リンクの色", hex: $appearance.linkColorHex,
                                defaultColor: AppearanceSettings.defaultLinkColor)
                ColorSettingRow(title: "辞書で調べた語のハイライト", hex: $appearance.highlightColorHex,
                                defaultColor: AppearanceSettings.defaultHighlightColor)
                ColorSettingRow(title: "スレの背景", hex: $appearance.threadBackgroundHex,
                                defaultColor: .systemBackground)

                PostPreview(style: appearance.postStyle, background: appearance.threadBackground)
            } header: {
                Text("書き込みの文字")
            }

            Section {
                Picker("表示密度", selection: $appearance.density) {
                    ForEach(AppearanceSettings.Density.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                Picker("サムネイルの大きさ", selection: $appearance.thumbnailSize) {
                    ForEach(AppearanceSettings.ThumbnailSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                Picker("サムネイルの位置", selection: $appearance.thumbnailOnRight) {
                    Text("左").tag(false)
                    Text("右").tag(true)
                }
                Toggle("区切り線", isOn: $appearance.postSeparators)
                Toggle("名無しを隠す", isOn: $appearance.hideDefaultNames)
                Toggle("経過時間を表示", isOn: $appearance.showRelativeTime)
                Toggle("AAを専用フォントで表示", isOn: $appearance.asciiArtFont)
                Toggle("リンクを短く表示", isOn: $appearance.shortenLinks)
            } header: {
                Text("スレの表示")
            } footer: {
                Text("「名無しを隠す」は、そのスレで最も多い名前（名無しさん、風吹けば名無しなど）を表示しません。トリップ付きの名前は常に表示されます。「AAを専用フォントで表示」は、アスキーアートを見つけるとMS Pゴシック互換のフォント（Saitamaar）で画面幅に合わせて表示し、ずれないようにします。「リンクを短く表示」は、URLの代わりにサイト名（Imgur、X @ユーザー名、YouTubeなど）を表示します。長押しでコピーする本文には元のURLが残ります。")
            }

            Section {
                NavigationLink {
                    FontPickerView(title: String(localized: "辞書のフォント"),
                                   selection: $appearance.dictionaryFontFamily,
                                   defaultLabel: String(localized: "ヒラギノ角ゴシック（標準）"))
                } label: {
                    LabeledContent("フォント", value: fontLabel(appearance.dictionaryFontFamily,
                                                            default: String(localized: "ヒラギノ角ゴシック（標準）")))
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("大きさ")
                        Spacer()
                        Text(verbatim: "\(Int((userConfig.popupScale * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $userConfig.popupScale, in: 0.6...1.8, step: 0.05)
                }
            } header: {
                Text("辞書の文字")
            } footer: {
                Text("辞書ポップアップと辞書検索の文字です。")
            }

            // Hoshi Reader's "Popup" settings.
            Section {
                Toggle("全幅で下に表示", isOn: $userConfig.popupFullWidth)
                if !userConfig.popupFullWidth {
                    VStack {
                        HStack {
                            Text("幅")
                            Spacer()
                            Text(verbatim: "\(userConfig.popupWidth)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: .init(
                            get: { Double(userConfig.popupWidth) },
                            set: { userConfig.popupWidth = Int($0) }
                        ), in: 100...700, step: 10)
                    }
                }
                VStack {
                    HStack {
                        Text("高さ")
                        Spacer()
                        Text(verbatim: "\(userConfig.popupHeight)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: .init(
                        get: { Double(userConfig.popupHeight) },
                        set: { userConfig.popupHeight = Int($0) }
                    ), in: 100...800, step: 10)
                }
                Toggle("アクションバーを表示", isOn: $userConfig.popupActionBar)
                Toggle("透明にしない", isOn: $userConfig.popupDisableTransparency)
                Toggle("スワイプで閉じる", isOn: $userConfig.popupSwipeToDismiss)
                if userConfig.popupSwipeToDismiss {
                    VStack {
                        HStack {
                            Text("スワイプの距離")
                            Spacer()
                            Text(verbatim: "\(userConfig.popupSwipeThreshold)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: .init(
                            get: { Double(userConfig.popupSwipeThreshold) },
                            set: { userConfig.popupSwipeThreshold = Int($0) }
                        ), in: 20...80, step: 5)
                    }
                }
            } header: {
                Text("辞書ポップアップ")
            } footer: {
                Text("「全幅で下に表示」では、辞書が画面の下に横幅いっぱいで表示されます。オフにすると、タップした語のそばに表示されます。")
            }

            Section {
                Button("すべて初期設定に戻す", role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .navigationTitle("外観")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("外観の設定をすべて初期設定に戻しますか？",
                            isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("初期設定に戻す", role: .destructive) {
                appearance.resetAll()
                userConfig.popupScale = 1.0
            }
        }
    }

    private func themeLink(title: String, selection: Binding<String>) -> some View {
        NavigationLink {
            ThemePickerView(title: title, selection: selection)
        } label: {
            HStack {
                Text(title)
                Spacer()
                ThemeSwatch(palette: appearance.palette(forTheme: selection.wrappedValue),
                            isDark: appearance.themeOptions.first { $0.id == selection.wrappedValue }?.isDark)
                    .scaleEffect(0.8)
                Text(appearance.title(forTheme: selection.wrappedValue))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fontLabel(_ family: String, default defaultLabel: String) -> String {
        family.isEmpty ? defaultLabel : family
    }

    private static func sizeLabel(_ index: Int) -> String {
        [String(localized: "最小"), String(localized: "小"), String(localized: "やや小"),
         String(localized: "標準"), String(localized: "やや大"), String(localized: "大"),
         String(localized: "最大")][index]
    }
}

/// A colour that can be left at its default (stored as nil).
private struct ColorSettingRow: View {
    let title: LocalizedStringKey
    @Binding var hex: String?
    let defaultColor: UIColor

    var body: some View {
        HStack {
            ColorPicker(title, selection: Binding(
                get: { Color(uiColor: hex.flatMap(UIColor.init(hex:)) ?? defaultColor) },
                set: { hex = UIColor($0).hexString }
            ))
            if hex != nil {
                Button {
                    hex = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("初期設定に戻す"))
            }
        }
    }
}

/// A sample post, drawn exactly as threads draw posts.
private struct PostPreview: View {
    let style: PostTextStyle
    let background: Color?

    var body: some View {
        PostTextView(text: String(localized: "吾輩は猫である。名前はまだ無い。[>>1](donguri://res/1) どこで生れたかとんと見当がつかぬ。"),
                     scanNonJapaneseText: false,
                     style: style,
                     onTextSelected: { _ in nil },
                     onTapOutside: {},
                     onPostReply: { _ in },
                     onThreadRoute: { _ in })
            .padding(10)
            .background(background ?? Color(uiColor: .systemBackground),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .allowsHitTesting(false)
    }
}

/// Lists installed fonts, each previewed in itself.
struct FontPickerView: View {
    let title: String
    @Binding var selection: String
    let defaultLabel: String

    @State private var search = ""

    private var japanese: [String] { filter(AppearanceSettings.installedJapaneseFamilies) }
    private var others: [String] { filter(AppearanceSettings.otherInstalledFamilies) }

    var body: some View {
        List {
            if search.isEmpty {
                Section {
                    row(family: "", label: defaultLabel)
                }
            }
            if !japanese.isEmpty {
                Section {
                    ForEach(japanese, id: \.self) { row(family: $0, label: $0) }
                } header: {
                    Text("日本語フォント")
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.self) { row(family: $0, label: $0) }
                } header: {
                    Text("その他のフォント")
                } footer: {
                    Text("日本語の文字がないフォントでは、かなと漢字は標準のフォントで表示されます。")
                }
            }
        }
        .searchable(text: $search, prompt: "フォントを検索")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func filter(_ families: [String]) -> [String] {
        search.isEmpty ? families : families.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private func row(family: String, label: String) -> some View {
        Button {
            selection = family
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "あいうえお 漢字 Aa 123")
                        .font(Font(PostTextStyle.font(family: family, size: 19) as CTFont))
                        .foregroundStyle(.primary)
                }
                Spacer()
                if selection == family {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
