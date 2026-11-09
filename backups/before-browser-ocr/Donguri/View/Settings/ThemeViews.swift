//
//  ThemeViews.swift
//  Donguri
//
//  Picking a theme, and Chance-style theme editing: make your own from a
//  handful of colours, with a live preview of a thread.
//

import SwiftUI
import UIKit

/// Lists every theme with a swatch; tap to choose.
struct ThemePickerView: View {
    let title: String
    @Binding var selection: String

    @State private var appearance = AppearanceSettings.shared
    @State private var editing: CustomTheme?
    @State private var creatingNew = false

    var body: some View {
        List {
            Section {
                ForEach(appearance.themeOptions.filter { !$0.id.hasPrefix(AppearanceSettings.customPrefix) }) { option in
                    row(option)
                }
            } header: {
                Text("標準のテーマ")
            }

            Section {
                ForEach(appearance.themeOptions.filter { $0.id.hasPrefix(AppearanceSettings.customPrefix) }) { option in
                    row(option)
                        .swipeActions(edge: .trailing) {
                            if let theme = appearance.customTheme(id: option.id) {
                                Button(role: .destructive) {
                                    appearance.deleteCustomTheme(theme)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                                Button {
                                    editing = theme
                                } label: {
                                    Label("編集", systemImage: "pencil")
                                }
                                .tint(.accentColor)
                            }
                        }
                }
                Button {
                    creatingNew = true
                } label: {
                    Label("新しいテーマを作成", systemImage: "plus.circle")
                }
            } header: {
                Text("カスタムテーマ")
            } footer: {
                Text("今のテーマの色から始めて、背景・バー・文字・リンクなどの色を自由に変えられます。左にスワイプで編集・削除。")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { theme in
            NavigationStack {
                ThemeEditorView(theme: theme, isNew: false) { saved in
                    appearance.saveCustomTheme(saved)
                }
            }
        }
        .sheet(isPresented: $creatingNew) {
            NavigationStack {
                ThemeEditorView(theme: newTheme(), isNew: true) { saved in
                    appearance.saveCustomTheme(saved)
                    selection = AppearanceSettings.customPrefix + saved.id.uuidString
                }
            }
        }
    }

    private func newTheme() -> CustomTheme {
        let base = appearance.palette(forTheme: selection)
        let isDark = base?.isDark ?? (appearance.colorScheme == .dark || (appearance.colorScheme == nil && appearance.systemIsDark))
        let count = appearance.customThemes.count + 1
        return CustomTheme(name: String(localized: "マイテーマ \(count)"), from: base, isDark: isDark)
    }

    private func row(_ option: AppearanceSettings.ThemeOption) -> some View {
        Button {
            selection = option.id
            Haptics.play(.selection)
        } label: {
            HStack(spacing: 12) {
                ThemeSwatch(palette: option.palette, isDark: option.isDark)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .foregroundStyle(.primary)
                    if let isDark = option.isDark {
                        Text(isDark ? String(localized: "ダーク") : String(localized: "ライト"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selection == option.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Background with the text, title and accent colours on it.
struct ThemeSwatch: View {
    let palette: ThemePalette?
    let isDark: Bool?

    var body: some View {
        let background: Color = palette.map { Color(uiColor: $0.background) }
            ?? (isDark == true ? Color.black : isDark == false ? Color.white : Color(uiColor: .systemBackground))
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(background)
            .frame(width: 44, height: 32)
            .overlay {
                if let palette {
                    HStack(spacing: 3) {
                        Circle().fill(Color(uiColor: palette.text)).frame(width: 8, height: 8)
                        Circle().fill(Color(uiColor: palette.title)).frame(width: 8, height: 8)
                        Circle().fill(Color(uiColor: palette.accent)).frame(width: 8, height: 8)
                    }
                } else if isDark == nil {
                    // システムに合わせる: half light, half dark.
                    HStack(spacing: 0) {
                        Color.white
                        Color.black
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.15)))
    }
}

/// Edits one custom theme's name and colours.
struct ThemeEditorView: View {
    @State var theme: CustomTheme
    let isNew: Bool
    var onSave: (CustomTheme) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                ThemePreview(palette: theme.palette)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                TextField("テーマの名前", text: $theme.name)
                Toggle("ダークテーマ", isOn: $theme.isDark)
            } footer: {
                Text("ダークテーマでは、メニューやキーボードなどシステムの部品も暗くなります。")
            }

            Section {
                hexPicker("背景", $theme.background)
                hexPicker("バー・カード", $theme.bar)
                hexPicker("文字", $theme.text)
                hexPicker("補助の文字", $theme.secondaryText)
                hexPicker("スレタイ", $theme.title)
                hexPicker("リンク", $theme.link)
                hexPicker("アクセント", $theme.accent)
            } header: {
                Text("色")
            }

            Section {
                Menu {
                    ForEach(AppearanceSettings.BuiltInTheme.allCases.filter { $0.palette != nil }) { builtIn in
                        Button(builtIn.title) {
                            copy(from: builtIn.palette)
                        }
                    }
                } label: {
                    Label("ほかのテーマの色をコピー", systemImage: "doc.on.doc")
                }
            }
        }
        .navigationTitle(isNew ? Text("新しいテーマ") : Text("テーマを編集"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    if theme.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        theme.name = String(localized: "マイテーマ")
                    }
                    onSave(theme)
                    Haptics.play(.success)
                    dismiss()
                }
            }
        }
    }

    private func hexPicker(_ title: LocalizedStringKey, _ hex: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(uiColor: UIColor(hex: hex.wrappedValue) ?? .gray) },
            set: { hex.wrappedValue = UIColor($0).hexString }
        ), supportsOpacity: false)
    }

    private func copy(from palette: ThemePalette?) {
        guard let palette else { return }
        let copied = CustomTheme(name: theme.name, from: palette, isDark: palette.isDark)
        theme.isDark = copied.isDark
        theme.background = copied.background
        theme.bar = copied.bar
        theme.text = copied.text
        theme.secondaryText = copied.secondaryText
        theme.accent = copied.accent
        theme.link = copied.link
        theme.title = copied.title
    }
}

/// A miniature thread in the theme's colours.
struct ThemePreview: View {
    let palette: ThemePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "chevron.left")
                Spacer()
                Text(verbatim: "なんでも実況J")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(uiColor: palette.text))
                Spacer()
                Image(systemName: "star")
            }
            .foregroundStyle(Color(uiColor: palette.accent))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(uiColor: palette.bar))

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "【悲報】ワイ、日本語の勉強を始める Part2")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color(uiColor: palette.title))
                HStack(spacing: 6) {
                    Text(verbatim: "#1")
                    let colors = IDColor.colors(for: "AbCdEf12")
                    Text(verbatim: "AbCdEf12")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(colors.foreground)
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(colors.background))
                    Spacer()
                    Text(verbatim: "21:04")
                }
                .font(.caption2)
                .foregroundStyle(Color(uiColor: palette.secondaryText))
                (Text(verbatim: ">>2 ").foregroundStyle(Color(uiColor: palette.link))
                    + Text(verbatim: "吾輩は猫である。名前はまだ無い。").foregroundStyle(Color(uiColor: palette.text)))
                    .font(.subheadline)
                HStack {
                    Spacer()
                    Text(verbatim: "↩︎ 3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(uiColor: palette.accent))
                }
            }
            .padding(14)
        }
        .background(Color(uiColor: palette.background))
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
    }
}
