import AppKit
import SwiftUI
import SwitcherCore

/// The settings panes, in toolbar order.
enum SettingsPane: Int, CaseIterable {
    case profiles, general, switcher, shortcuts, links, about

    var title: String {
        switch self {
        case .profiles: String(localized: "Profiles")
        case .general: String(localized: "General")
        case .switcher: String(localized: "Switcher")
        case .shortcuts: String(localized: "Shortcuts")
        case .links: String(localized: "Links")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .profiles: "person.2"
        case .general: "gearshape"
        case .switcher: "rectangle.3.group"
        case .shortcuts: "keyboard"
        case .links: "link"
        case .about: "info.circle"
        }
    }

    /// The pane's content, as tall as it needs to be: the window takes its height, nothing scrolls.
    @MainActor
    func view(controller: AppController, settings: AppSettings) -> AnyView {
        let content: AnyView = switch self {
        case .profiles: AnyView(ProfileSettings(controller: controller, settings: settings))
        case .general: AnyView(GeneralSettings(controller: controller, settings: settings))
        case .switcher: AnyView(ShortcutSettings(controller: controller, settings: settings, switcher: true))
        case .shortcuts: AnyView(ShortcutSettings(controller: controller, settings: settings, switcher: false))
        case .links: AnyView(LinkSettings(controller: controller, settings: settings))
        case .about: AnyView(AboutSettings(controller: controller))
        }
        return AnyView(content
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 640))
    }

    @MainActor
    func viewController(controller: AppController, settings: AppSettings) -> NSViewController {
        let hosting = NSHostingController(rootView: view(controller: controller, settings: settings))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.title = title
        return hosting
    }
}

/// The settings window: a toolbar with the panes, like System Settings' older style and most Mac apps.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let tabs = NSTabViewController()
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for pane in SettingsPane.allCases {
            let item = NSTabViewItem(viewController: pane.viewController(controller: controller, settings: controller.settings))
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Brings the window to the front. A menu bar app has no Dock icon and isn't in ⌘⇥, so it can stay
    /// behind other apps' windows; while the settings are open it becomes a regular app.
    func show() {
        controller.refreshPermissions()
        controller.refreshProfiles()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Switching") {
                Toggle("Close a window that only shows the start page", isOn: $settings.closeEmptyWindow)
                Toggle("Open the new window in place of the current one", isOn: $settings.newWindowInPlace)
                Toggle("Keep full screen for the new window", isOn: $settings.matchFullScreen)
                    .disabled(!settings.newWindowInPlace)
                Toggle("Also move existing windows onto the current window", isOn: $settings.alignExistingWindows)
                Toggle("Copy the tab instead of moving it to the next profile", isOn: $settings.keepSourceTab)
                Picker("Switch shortcut outside Safari", selection: $settings.outsideSafariAction) {
                    ForEach(OutsideSafariAction.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }))
            }
        }
    }
}

private struct ProfileSettings: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(knownProfiles, id: \.self) { profileRow($0) }
                if !controller.profileWarnings.isEmpty {
                    ForEach(controller.profileWarnings, id: \.self) { warning in
                        Label(warning.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                Button("Refresh profile list") { controller.refreshProfiles() }
            } header: {
                Text("Safari profiles")
            } footer: {
                Text("The switch shortcut goes through the checked profiles in this order. The badge and color show the profile in the menu bar and the switcher.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Menu bar shows", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Menu bar")
            } footer: {
                Text("The badge is the profile of Safari's front window; faded while another app is in front.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Profiles to switch between first (in their order), then the other detected ones.
    private var knownProfiles: [String] { controller.knownProfiles }

    private func badgeBinding(_ profile: String) -> Binding<String> {
        Binding(
            get: { settings.profileBadges[profile] ?? "" },
            set: { settings.profileBadges[profile] = $0.isEmpty ? nil : String($0.prefix(4)) })
    }

    /// A checkbox rather than a text field, so a stray keystroke (e.g. ⌥⇥) can't change a name.
    private func profileRow(_ profile: String) -> some View {
        let index = settings.switchProfiles.firstIndex(of: profile)
        let look = controller.look(for: profile)
        return HStack {
            Toggle(isOn: Binding(get: { index != nil }, set: { settings.setSwitching(profile, $0) })) {
                HStack(spacing: 6) {
                    ProfileBadge(look: look, size: 20)
                    Text(look.name)
                }
            }
            if profile != ProfileMatcher.privateProfile && !controller.detectedProfiles.isEmpty
                && !controller.detectedProfiles.contains(profile) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help(ProfileWarning.missingProfile(profile).message)
            }
            Spacer()
            TextField("Badge", text: badgeBinding(profile), prompt: Text(look.isPrivate ? "✋" : look.badge))
                .labelsHidden()
                .frame(width: 44)
                .help("Badge text (up to 4 characters)")
            Menu {
                ForEach(ProfileColor.allCases) { color in
                    Button {
                        settings.profileColors[profile] = color.rawValue
                    } label: {
                        Label { Text(color.title) } icon: {
                            Image(nsImage: .swatch(color.color))
                        }
                    }
                }
            } label: {
                Image(nsImage: .swatch(look.color))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Badge color")
            if let index {
                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                Button { settings.moveSwitching(profile, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { settings.moveSwitching(profile, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == settings.switchProfiles.count - 1)
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    /// The switcher's pane (how it looks, its keys) rather than the Safari shortcuts.
    let switcher: Bool
    @State private var note: String?

    var body: some View {
        Form {
            if switcher { switcherSections } else { safariSections }
            if let note {
                Section { Text(note).foregroundStyle(.orange) }
            }
        }
    }

    @ViewBuilder private var switcherSections: some View {
        Section {
            Picker("Show", selection: $settings.hudMode) {
                ForEach(HUDMode.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Delay before it appears") {
                HStack {
                    Slider(value: $settings.hudDelay, in: 0...0.6, step: 0.05)
                    Text("\(Int(settings.hudDelay * 1000)) ms").monospacedDigit().frame(width: 60, alignment: .trailing)
                }
            }
            .disabled(settings.hudMode == .off)
        } header: {
            Text("Switcher (hold the modifier of the switch shortcut)")
        }
        Section {
            ForEach(ShortcutAction.allCases.filter { !$0.scopes.contains(.safari) && $0.isConfigurable }) { row($0) }
        } header: {
            Text("While the switcher is open")
        } footer: {
            Text("The switch shortcut also selects the next profile (in the window list, the next window), and with ⇧ the previous one. In the window list, next / previous go through the window's tabs. Release the modifier to confirm.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var safariSections: some View {
            Section {
                ForEach(ShortcutAction.allCases.filter { $0.scopes.contains(.safari) }) { row($0) }
            } header: {
                Text("In Safari")
            } footer: {
                Text("Registered only while Safari is the front app, so other apps keep these keys.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Go to profile 1…9", selection: $settings.profileNumberModifier) {
                    ForEach(NumberModifier.allCases) { Text($0.title).tag($0) }
                }
                Picker("Move tab to profile 1…9", selection: $settings.moveTabNumberModifier) {
                    ForEach(NumberModifier.allCases) { Text($0.title).tag($0) }
                }
                ForEach(controller.numberedHotKeyFailures, id: \.self) { failure in
                    Text(failure).foregroundStyle(.red)
                }
            } header: {
                Text("Profiles by number")
            } footer: {
                Text("The number is the profile's place in the list on the Profiles tab. Only while Safari is in front; keys an action above uses are left to it.")
                    .foregroundStyle(.secondary)
            }
    }

    private func row(_ action: ShortcutAction) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                ShortcutRecorder(
                    shortcut: settings.shortcuts[action],
                    onChange: { assign($0, to: action) },
                    onRecordingChange: controller.setHotKeyPaused)
                Button {
                    assign(action.defaultShortcut, to: action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Default")
                .disabled(settings.shortcuts[action] == action.defaultShortcut)
                Button {
                    assign(nil, to: action)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Turn off")
                .disabled(settings.shortcuts[action] == nil)
            }
            .buttonStyle(.borderless)
        } label: {
            Text(action.title)
            if let failure = controller.hotKeyFailures[action] {
                Text(failure).foregroundStyle(.red)
            }
        }
    }

    private func assign(_ shortcut: Shortcut?, to action: ShortcutAction) {
        guard let other = settings.setShortcut(shortcut, for: action) else {
            note = nil
            return
        }
        note = if let swapped = settings.shortcuts[other] {
            String(localized: "“\(other.title)” now uses \(swapped.displayString).")
        } else {
            String(localized: "“\(other.title)” was turned off: it used the same keys.")
        }
    }
}

private struct AboutSettings: View {
    @ObservedObject var controller: AppController
    @StateObject private var liveCheck = LiveCheck()
    @State private var settingsNote: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "Safari Profile Switcher").font(.title2.weight(.semibold))
                        Text("Version \(Self.version)").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack {
                        Text(controller.accessibilityGranted ? String(localized: "✅ Allowed")
                             : String(localized: "⚠️ No access"))
                        if !controller.accessibilityGranted {
                            Button("Open Settings") { controller.openAccessibilitySettings() }
                        }
                    }
                }
                LabeledContent("Safari automation") {
                    HStack {
                        Text(controller.automationStatus)
                        Button("Request") { controller.requestAutomation() }
                    }
                }
            }
            Section {
                Button("Check how it works") { Task { await liveCheck.run() } }
                    .disabled(liveCheck.isRunning)
                ForEach(liveCheck.steps) { step in
                    LabeledContent {
                        Text(step.detail).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    } label: {
                        HStack(spacing: 6) {
                            switch step.passed {
                            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case false?: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            case nil: ProgressView().controlSize(.small)
                            }
                            Text(step.name)
                        }
                    }
                }
            } header: {
                Text("Check")
            } footer: {
                Text("Tries what needs Accessibility on Safari: profile and private windows from the File menu, moving a tab to a new window, raising a window. Opens and closes its own temporary windows; yours stay as they are.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Export…") { exportSettings() }
                    Button("Import…") { importSettings() }
                    if let settingsNote {
                        Text(settingsNote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Settings file")
            } footer: {
                Text("Profiles, shortcuts, link rules, colors and options, to back up or move to another Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Save Safari diagnostics") { controller.writeDiagnostics() }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Windows and menus of Safari in ~/Library/Logs/SafariProfileSwitcher/diagnostics.txt")
                    .foregroundStyle(.secondary)
            }
            if let error = controller.lastError {
                Section("Last error") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            controller.refreshPermissions()
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Safari Profile Switcher.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.settings.exportData().write(to: url, options: .atomic)
            settingsNote = String(localized: "Exported")
        } catch {
            controller.fail(error.localizedDescription)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.settings.importData(Data(contentsOf: url))
            controller.refreshProfiles()
            settingsNote = String(localized: "Imported")
        } catch {
            controller.fail(error.localizedDescription)
            settingsNote = error.localizedDescription
        }
    }

    /// "1.1.0 (5)": the version and the build number (commit count) from Info.plist.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
