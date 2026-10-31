import AppKit
import SwiftUI
import SwitcherCore

/// The ⌘⇥-style switcher: a panel that doesn't take focus from Safari.
@MainActor
final class SwitcherHUD {
    final class Model: ObservableObject {
        @Published var state = HUDState(items: [], selection: 0)
        var badge: (String) -> String = { String($0.prefix(1)) }
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
        let screen = Self.screen(containing: frame) ?? NSScreen.main
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
        let items = Array(model.state.items.enumerated())
        if items.first.map({ if case .profile = $0.element.target { true } else { false } }) ?? true {
            HStack(spacing: 8) {
                ForEach(items, id: \.offset) { index, item in
                    ProfileTile(item: item, badge: model.badge(item.title), selected: index == model.state.selection)
                        .onTapGesture { model.onClick(index) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items.prefix(14), id: \.offset) { index, item in
                    WindowRow(item: item, badge: item.profile.map(model.badge), selected: index == model.state.selection)
                        .onTapGesture { model.onClick(index) }
                }
            }
            .frame(width: 440)
        }
    }
}

private struct ProfileTile: View {
    let item: HUDItem
    let badge: String
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(badge)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .frame(width: 64, height: 64)
                .background(Circle().fill(.quaternary))
            Text(item.title).font(.headline).lineLimit(1)
            Text(item.count == 0 ? String(localized: "no windows") : String(localized: "\(item.count) windows"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 110)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.35) : .clear))
        .contentShape(Rectangle())
    }
}

private struct WindowRow: View {
    let item: HUDItem
    let badge: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(badge ?? "•")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? String(localized: "Start Page") : item.title).lineLimit(1)
                Text(item.profile ?? String(localized: "Other windows")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if item.count > 1 {
                Text("\(item.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
