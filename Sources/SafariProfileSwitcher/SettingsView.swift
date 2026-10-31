import SwiftUI
import SwitcherCore

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    @State var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(controller: controller, settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            ShortcutSettings(controller: controller, settings: settings)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(1)
            LinkSettings(controller: controller, settings: settings)
                .tabItem { Label("Links", systemImage: "link") }.tag(2)
            PermissionSettings(controller: controller)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(3)
        }
        .frame(width: 640, height: 600)
        .onAppear {
            controller.refreshPermissions()
            controller.refreshProfiles()
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Safari profiles") {
                profileRow("First profile", selection: $settings.firstProfile)
                profileRow("Second profile", selection: $settings.secondProfile)
                Button("Refresh profile list") { controller.refreshProfiles() }
            }
            Section("Switching") {
                Toggle("Close a window that only shows the start page", isOn: $settings.closeEmptyWindow)
                Toggle("Open the new window in place of the current one", isOn: $settings.newWindowInPlace)
                Toggle("Keep full screen for the new window", isOn: $settings.matchFullScreen)
                    .disabled(!settings.newWindowInPlace)
                Toggle("Also move existing windows onto the current window", isOn: $settings.alignExistingWindows)
                Toggle("Copy the tab instead of moving it to the other profile", isOn: $settings.keepSourceTab)
                Picker("Switch shortcut outside Safari", selection: $settings.outsideSafariAction) {
                    ForEach(OutsideSafariAction.allCases) { Text($0.title).tag($0) }
                }
            }
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
            Section("Menu bar") {
                Toggle("Show the active profile in the menu bar", isOn: $settings.showProfileIndicator)
                ForEach(knownProfiles, id: \.self) { profile in
                    LabeledContent(profile) {
                        TextField("", text: badgeBinding(profile), prompt: Text(settings.badge(for: profile)))
                            .labelsHidden()
                            .frame(width: 80)
                    }
                }
                .disabled(!settings.showProfileIndicator)
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
    }

    private var knownProfiles: [String] {
        var seen = Set<String>()
        return (settings.profilePair + controller.detectedProfiles).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func badgeBinding(_ profile: String) -> Binding<String> {
        Binding(
            get: { settings.profileBadges[profile] ?? "" },
            set: { settings.profileBadges[profile] = $0.isEmpty ? nil : String($0.prefix(4)) })
    }

    /// A picker rather than a text field, so a stray keystroke (e.g. ⌥⇥) can't overwrite the name.
    private func profileRow(_ label: LocalizedStringKey, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            if !controller.detectedProfiles.contains(selection.wrappedValue) {
                Text(selection.wrappedValue.isEmpty ? String(localized: "Not selected") : selection.wrappedValue)
                    .tag(selection.wrappedValue)
            }
            ForEach(controller.detectedProfiles, id: \.self) { name in
                Text(name).tag(name)
            }
        }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases.filter { $0.scopes.contains(.safari) }) { row($0) }
            } header: {
                Text("In Safari")
            } footer: {
                Text("Registered only while Safari is the front app, so other apps keep these keys.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(ShortcutAction.allCases.filter { !$0.scopes.contains(.safari) }) { row($0) }
            } header: {
                Text("While the switcher is open")
            } footer: {
                Text("The switch shortcut also selects the next item. Release the modifier to confirm.")
                    .foregroundStyle(.secondary)
            }
            if let note {
                Section { Text(note).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
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

private struct PermissionSettings: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            controller.refreshPermissions()
        }
    }
}
