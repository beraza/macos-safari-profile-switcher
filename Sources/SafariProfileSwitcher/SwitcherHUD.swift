import AppKit
import SwiftUI
import SwitcherCore

/// The ⌘⇥-style switcher: a panel that doesn't take focus from Safari.
@MainActor
final class SwitcherHUD {
    final class Model: ObservableObject {
        @Published var state = HUDState(items: [], selection: 0)
        var look: (String?) -> ProfileLook = { _ in .unknown }
        var onClick: (Int) -> Void = { _ in }
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
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(state.items.enumerated().prefix(14)), id: \.offset) { index, item in
                    WindowRow(item: item, look: model.look(item.profile), showProfile: true,
                              selected: index == state.selection)
                        .onTapGesture { model.onClick(index) }
                }
            }
            .frame(width: 440)
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
                WindowRow(item: item, look: look, showProfile: false, selected: index == model.state.selection)
                    .onTapGesture { model.onClick(index) }
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

private struct WindowRow: View {
    let item: HUDItem
    let look: ProfileLook
    let showProfile: Bool
    let selected: Bool

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
                    Text(item.title.isEmpty ? String(localized: "Start Page") : item.title).lineLimit(1)
                    if showProfile {
                        Text(item.profile == nil ? String(localized: "Other windows") : look.name)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 6)
            if item.count > 1 {
                Text("\(item.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.35) : .clear))
        .contentShape(Rectangle())
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
