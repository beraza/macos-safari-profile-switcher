import AppKit
import SwiftUI
import SwitcherCore

/// The ⌘⇥-style switcher: a panel that doesn't take focus from Safari.
@MainActor
final class SwitcherHUD {
    final class Model: ObservableObject {
        @Published var state = HUDState(items: [], selection: 0)
        /// A close shortcut was pressed once on the selected tab or window; the next press closes it.
        @Published var pendingClose: HUDController.CloseTarget?
        var look: (String?) -> ProfileLook = { _ in .unknown }
        /// An item was clicked, or one of its tabs (0-based).
        var onClick: (Int, Int?) -> Void = { _, _ in }
    }

    let model = Model()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ state: HUDState, near frame: CGRect?) {
        model.state = state
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? CGSize(width: 400, height: 160)
        panel.setContentSize(size)
        // Outside Safari (or without windows), on the screen with the pointer.
        let screen = Self.screen(containing: frame)
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
    }

    /// Writes the panel's content as PNG (self-test).
    func snapshot(to url: URL) throws {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func update(_ state: HUDState) {
        model.state = state
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The screen of a window frame in AppleScript coordinates (top-left origin of the main screen).
    private static func screen(containing frame: CGRect?) -> NSScreen? {
        guard let frame, let primary = NSScreen.screens.first else { return nil }
        let center = NSPoint(x: frame.midX, y: primary.frame.maxY - frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }
}

private struct HUDView: View {
    @ObservedObject var model: SwitcherHUD.Model

    var body: some View {
        content
            .padding(14)
            .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
            .fixedSize()
    }

    @ViewBuilder private var content: some View {
        let state = model.state
        if state.groups.isEmpty {
            let showTabs = state.items.contains { !$0.tabs.isEmpty }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(state.items.enumerated().prefix(14)), id: \.offset) { index, item in
                    let selected = index == state.selection
                    let closingWindow = selected && model.pendingClose == .window
                    HStack(spacing: 8) {
                        WindowRow(item: item, look: model.look(item.profile), showProfile: true,
                                  selected: false, showCount: !showTabs, closing: closingWindow)
                            .frame(width: showTabs ? 250 : 440, alignment: .leading)
                            .onTapGesture { model.onClick(index, nil) }
                        if showTabs {
                            TabStrip(item: item, selectedTab: selected ? state.selectedTab : nil,
                                     pendingClose: selected && model.pendingClose == .tab) { model.onClick(index, $0) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(
                        closingWindow ? Color.red.opacity(0.55) : selected ? Color.accentColor.opacity(0.35) : .clear))
                }
            }
            .frame(width: showTabs ? 780 : 440, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(state.groups.enumerated()), id: \.offset) { groupIndex, group in
                    ProfileColumn(model: model, group: group, current: groupIndex == 0 && state.groups.count > 1,
                                  active: state.selectedGroup == groupIndex)
                }
            }
        }
    }
}

/// A profile and its windows. Long lists show a slice around the selection.
private struct ProfileColumn: View {
    @ObservedObject var model: SwitcherHUD.Model
    let group: HUDGroup
    /// The front window's profile.
    let current: Bool
    /// Holds the selection.
    let active: Bool

    private static let visibleRows = 8

    var body: some View {
        let look = model.look(group.profile)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ProfileBadge(look: look, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.profile == nil ? String(localized: "Other windows") : look.name)
                        .font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            ForEach(rows, id: \.self) { index in
                let item = model.state.items[index]
                let selected = index == model.state.selection
                WindowRow(item: item, look: look, showProfile: false, selected: selected,
                          closing: selected && model.pendingClose == .window)
                    .onTapGesture { model.onClick(index, nil) }
                if selected && !item.tabs.isEmpty {
                    TabList(item: item, selectedTab: model.state.selectedTab,
                            pendingClose: model.pendingClose == .tab) { model.onClick(index, $0) }
                }
            }
            if hidden > 0 {
                Text("+\(hidden)").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
        }
        .padding(8)
        .frame(width: 220, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(active ? Color.primary.opacity(0.07) : .clear))
    }

    private var subtitle: String {
        let count = group.windowCount == 0 ? String(localized: "no windows") : String(localized: "\(group.windowCount) windows")
        return current ? String(localized: "Current · \(count)") : count
    }

    private var rows: [Int] {
        let all = Array(group.items)
        guard all.count > Self.visibleRows else { return all }
        let selected = all.firstIndex(of: model.state.selection) ?? 0
        let start = min(max(0, selected - Self.visibleRows / 2), all.count - Self.visibleRows)
        return Array(all[start..<start + Self.visibleRows])
    }

    private var hidden: Int { group.items.count - rows.count }
}

/// Up to `visible` tab indexes around the selected (or current) tab.
private func tabSlice(_ item: HUDItem, selectedTab: Int?, visible: Int) -> [Int] {
    let count = item.tabs.count
    guard count > visible else { return Array(0..<count) }
    let focus = selectedTab ?? item.currentTab
    let start = min(max(0, focus - visible / 2), count - visible)
    return Array(start..<start + visible)
}

/// The tabs of the selected window under it in a profile column: the current tab in bold, the selected one
/// highlighted (red while the close shortcut waits). Long lists show a slice around the selection.
private struct TabList: View {
    let item: HUDItem
    let selectedTab: Int?
    let pendingClose: Bool
    let onClick: (Int) -> Void

    private static let visible = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(slice, id: \.self) { index in
                let selected = index == selectedTab
                let closing = selected && pendingClose
                HStack(spacing: 4) {
                    if closing { Image(systemName: "xmark.circle.fill") }
                    Text(closing ? String(localized: "Close? ⌥W")
                         : item.tabs[index].isEmpty ? String(localized: "Start Page") : item.tabs[index])
                        .fontWeight(index == item.currentTab ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(
                    closing ? Color.red : selected ? Color.accentColor : .clear))
                .contentShape(Rectangle())
                .onTapGesture { onClick(index) }
            }
            if item.tabs.count > slice.count {
                Text("+\(item.tabs.count - slice.count)").font(.caption2).foregroundStyle(.secondary).padding(.leading, 8)
            }
        }
        .padding(.leading, 18)
        .padding(.bottom, 4)
    }

    private var slice: [Int] { tabSlice(item, selectedTab: selectedTab, visible: Self.visible) }
}

/// The tabs of a window as chips: the current tab in bold, the selected one highlighted (red while the
/// close shortcut waits for its second press). Long lists show a slice around the selection.
private struct TabStrip: View {
    let item: HUDItem
    let selectedTab: Int?
    let pendingClose: Bool
    let onClick: (Int) -> Void

    private static let visible = 4

    var body: some View {
        HStack(spacing: 4) {
            ForEach(slice, id: \.self) { index in
                chip(index)
                    .onTapGesture { onClick(index) }
            }
            if item.tabs.count > slice.count {
                Text("+\(item.tabs.count - slice.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
    }

    private func chip(_ index: Int) -> some View {
        let selected = index == selectedTab
        let closing = selected && pendingClose
        let title = item.tabs[index].isEmpty ? String(localized: "Start Page") : item.tabs[index]
        return HStack(spacing: 3) {
            if closing { Image(systemName: "xmark.circle.fill") }
            Text(closing ? String(localized: "Close? ⌥W") : title)
                .fontWeight(index == item.currentTab ? .semibold : .regular)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: 112)
        .background(RoundedRectangle(cornerRadius: 6).fill(
            closing ? Color.red : selected ? Color.accentColor : Color.primary.opacity(index == item.currentTab ? 0.14 : 0.07)))
        .help(item.tabs[index])
    }

    private var slice: [Int] { tabSlice(item, selectedTab: selectedTab, visible: Self.visible) }
}

private struct WindowRow: View {
    let item: HUDItem
    let look: ProfileLook
    let showProfile: Bool
    let selected: Bool
    var showCount = true
    /// The close-window shortcut waits for its second press.
    var closing = false

    var body: some View {
        HStack(spacing: 8) {
            if showProfile {
                ProfileBadge(look: look, size: 24)
            }
            if case .profile = item.target {
                VStack(alignment: .leading, spacing: 1) {
                    Label(look.isPrivate ? String(localized: "New Private Window") : String(localized: "New Window"),
                          systemImage: "plus")
                        .foregroundStyle(.secondary)
                    if showProfile {
                        Text(look.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(closing ? String(localized: "Close the window? ⌥⇧W")
                         : item.title.isEmpty ? String(localized: "Start Page") : item.title).lineLimit(1)
                    if showProfile {
                        Text(item.profile == nil ? String(localized: "Other windows") : look.name)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 6)
            if showCount && item.count > 1 {
                Text("\(item.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            closing ? Color.red.opacity(0.55) : selected ? Color.accentColor.opacity(0.35) : .clear))
        .contentShape(Rectangle())
    }
}

/// A blurred panel background.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
