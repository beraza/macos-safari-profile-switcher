import AppKit
import Combine
import SwiftUI
import SwitcherCore

/// ⌃⌥F: a search field over the tabs of all windows, so of all profiles at once (Safari's own tab search
/// stays within a window). ↑/↓ choose, ↩ goes to the tab, ⎋ or a click elsewhere closes.
@MainActor
final class TabSearchPanel {
    final class Model: ObservableObject {
        @Published var query = "" { didSet { selection = 0 } }
        @Published var selection = 0
        /// Changed on every show, so the field takes the keyboard focus again.
        @Published var focusRequest = 0
        var windows: [SafariWindow] = []
        var tabs: [Int: WindowTabs] = [:]
        var profiles: [String] = []
        var look: (String?) -> ProfileLook = { _ in .unknown }
        var onChoose: (TabSearchResult) -> Void = { _ in }
        var onCancel: () -> Void = {}

        static let limit = 12

        var results: [TabSearchResult] {
            Array(TabSearch.results(query: query, windows: windows, tabs: tabs, profiles: profiles).prefix(Self.limit))
        }

        func move(_ offset: Int) {
            let count = results.count
            guard count > 0 else { return }
            selection = (selection + offset + count) % count
        }
    }

    private weak var controller: AppController?
    private let model = Model()
    private var panel: KeyPanel?
    private var hosting: NSHostingView<TabSearchView>?
    /// Where the panel's top edge stays while the list below it grows and shrinks.
    private var topLeft = NSPoint.zero
    /// ↑/↓ for the list: the text field's editor would take them for the cursor.
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    init(controller: AppController) {
        self.controller = controller
        model.onChoose = { [weak self] result in
            self?.hide()
            self?.controller?.showTab(windowID: result.windowID, tab: result.tabIndex)
        }
        model.onCancel = { [weak self] in self?.hide() }
        // Resize after SwiftUI has laid out the new results.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fitToContent() }
            .store(in: &cancellables)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        guard let controller else { return }
        do {
            model.windows = try controller.safari.windows()
            model.tabs = try controller.safari.tabs()
        } catch {
            controller.fail(error.localizedDescription)
            return
        }
        let profiles = controller.knownProfiles
        model.profiles = profiles
        model.look = { [settings = controller.settings] profile in
            profile.map { settings.look(for: $0, among: profiles) } ?? .unknown
        }
        model.query = ""
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Like Spotlight: centered, in the upper part of the screen; the list grows downwards.
            topLeft = NSPoint(x: visible.midX - 320, y: visible.maxY - visible.height * 0.2)
        }
        fitToContent()
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel?.isKeyWindow == true else { return event }
                switch Int(event.keyCode) {
                case 125: self.model.move(1) // ↓
                case 126: self.model.move(-1) // ↑
                default: return event
                }
                return nil
            }
        }
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
    }

    /// Sizes the panel to its content with the top edge in place.
    private func fitToContent() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
                       display: true)
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 80),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.onResignKey = { [weak self] in self?.hide() }
        let hosting = NSHostingView(rootView: TabSearchView(model: model))
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }
}

/// A panel that takes the keyboard without activating the app (so Safari stays the active app).
final class KeyPanel: NSPanel {
    var onResignKey: () -> Void = {}

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }
}

struct TabSearchView: View {
    @ObservedObject var model: TabSearchPanel.Model
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.results
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tabs in all profiles", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { choose(results) }
                    .onExitCommand { model.onCancel() }
            }
            .padding(14)
            if !results.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                        ResultRow(result: result, look: model.look(result.profile), selected: index == model.selection)
                            .onTapGesture { model.onChoose(result) }
                    }
                }
                .padding(6)
            } else if !model.query.isEmpty {
                Divider()
                Text("No tabs found").foregroundStyle(.secondary).padding(14)
            }
        }
        .frame(width: 640)
        .background(VisualEffect(material: .popover).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { focused = true }
    }

    private func choose(_ results: [TabSearchResult]) {
        guard results.indices.contains(model.selection) else { return }
        model.onChoose(results[model.selection])
    }
}

private struct ResultRow: View {
    let result: TabSearchResult
    let look: ProfileLook
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProfileBadge(look: look, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title.isEmpty ? String(localized: "Start Page") : result.title).lineLimit(1)
                Text(URL(string: result.url)?.host() ?? result.url)
                    .font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(look.name).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }
}
