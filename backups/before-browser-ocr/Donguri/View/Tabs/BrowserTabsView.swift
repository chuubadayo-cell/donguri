//
//  BrowserTabsView.swift
//  Donguri
//
//  The 板 tab, as Chance's browse tab: several tabs, each a navigation
//  stack of its own. The few most recently used stay alive while hidden, so
//  switching back is instant and keeps the scroll position.
//

import SwiftUI

struct BrowserTabsView: View {
    @State private var navigator = AppNavigator.shared

    var body: some View {
        ZStack {
            ForEach(navigator.liveTabs) { tab in
                let isCurrent = tab.id == navigator.currentTabID
                BrowserTabStack(tabID: tab.id, isActive: isCurrent)
                    .opacity(isCurrent ? 1 : 0)
                    .allowsHitTesting(isCurrent)
                    .accessibilityHidden(!isCurrent)
                    .zIndex(isCurrent ? 1 : 0)
            }
        }
        .sheet(isPresented: $navigator.showsTabSwitcher) {
            TabSwitcherView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// One browser tab's navigation stack.
private struct BrowserTabStack: View {
    let tabID: UUID
    let isActive: Bool

    @State private var navigator = AppNavigator.shared
    @State private var context: BrowseContext

    init(tabID: UUID, isActive: Bool) {
        self.tabID = tabID
        self.isActive = isActive
        _context = State(initialValue: BrowseContext(tabID: tabID))
    }

    var body: some View {
        NavigationStack(path: navigator.pathBinding(for: tabID)) {
            BBSMenuView()
                .browseDestinations()
                .background(FullSwipeBack())
        }
        .environment(context)
        .onChange(of: isActive, initial: true) { _, active in
            if context.isActive != active { context.isActive = active }
        }
    }
}

/// Toolbar button showing how many tabs are open. Tap for the switcher,
/// hold for new tab / close tab.
struct TabsToolbarButton: View {
    @Environment(BrowseContext.self) private var browseContext: BrowseContext?
    @State private var navigator = AppNavigator.shared

    private var browse: BrowseContext { browseContext ?? .detached }

    var body: some View {
        if browse.isBrowserTab {
            Menu {
                Button {
                    navigator.openTab()
                } label: {
                    Label("新しいタブ", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) {
                    navigator.close(navigator.currentTabID)
                } label: {
                    Label("このタブを閉じる", systemImage: "xmark.square")
                }
            } label: {
                TabCountIcon(count: navigator.tabs.count)
            } primaryAction: {
                Haptics.play(.selection)
                navigator.showsTabSwitcher = true
            }
            .accessibilityLabel(Text("タブ"))
        }
    }
}

private struct TabCountIcon: View {
    let count: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(lineWidth: 1.6)
                .frame(width: 19, height: 19)
            Text(verbatim: count > 99 ? "∞" : "\(count)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
}

/// The open tabs, newest beside the one they were opened from.
struct TabSwitcherView: View {
    @State private var navigator = AppNavigator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCloseAll = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(navigator.tabs) { tab in
                        Button {
                            navigator.select(tab.id)
                            Haptics.play(.selection)
                            dismiss()
                        } label: {
                            TabRow(tab: tab, isCurrent: tab.id == navigator.currentTabID)
                        }
                        .buttonStyle(.plain)
                        .themedRow()
                        .id(tab.id)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                withAnimation { navigator.close(tab.id) }
                            } label: {
                                Label("閉じる", systemImage: "xmark")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation { navigator.close(tab.id) }
                            } label: {
                                Label("閉じる", systemImage: "xmark")
                            }
                            Button {
                                withAnimation { navigator.closeOthers(than: tab.id) }
                            } label: {
                                Label("他のタブを閉じる", systemImage: "xmark.square")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .onAppear {
                    proxy.scrollTo(navigator.currentTabID, anchor: .center)
                }
            }
            .themedScreen()
            .navigationTitle(Text("タブ \(navigator.tabs.count)件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("すべて閉じる", role: .destructive) {
                        confirmCloseAll = true
                    }
                    .disabled(navigator.tabs.count <= 1 && navigator.tabs.first?.path.isEmpty == true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        navigator.openTab()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("新しいタブ"))
                }
            }
            .confirmationDialog("すべてのタブを閉じますか？",
                                isPresented: $confirmCloseAll,
                                titleVisibility: .visible) {
                Button("すべて閉じる", role: .destructive) {
                    navigator.closeAll()
                    dismiss()
                }
            }
        }
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let isCurrent: Bool

    @State private var favorites = FavoritesStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.systemImage)
                .font(.body)
                .foregroundStyle(isCurrent ? Color.white : Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isCurrent ? Color.accentColor : Color.accentColor.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let subtitle = tab.subtitle {
                        Text(subtitle)
                    }
                    if tab.path.count > 1 {
                        Text("戻る履歴 \(tab.path.count - 1)")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let unread {
                Text(verbatim: "+\(unread)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.red)
            }
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// New posts in a favorite thread the tab shows.
    private var unread: Int? {
        guard case .thread(let link) = tab.path.last,
              let favorite = favorites.threads.first(where: { $0.id == link.key }) else { return nil }
        return favorites.unreadCount(for: favorite)
    }
}

/// The navigator's toast, floating above the tab bar.
struct NavigatorToast: View {
    @State private var navigator = AppNavigator.shared

    var body: some View {
        VStack {
            Spacer()
            if let toast = navigator.toast {
                HStack(spacing: 8) {
                    Image(systemName: "plus.square.on.square")
                    Text(toast)
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 64)
            }
        }
        .allowsHitTesting(false)
    }
}
