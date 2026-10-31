import AppKit
import SwiftUI
import SwitcherCore

/// Default browser switch, link rules and a field to try a link against them.
struct LinkSettings: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    @State private var testLink = ""
    @State private var testApp = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Default browser") {
                    HStack {
                        Text(controller.isDefaultBrowser ? String(localized: "✅ This app") : String(localized: "Another app"))
                        Button(controller.isDefaultBrowser ? "Give back to Safari" : "Make default") {
                            controller.setDefaultBrowser(!controller.isDefaultBrowser)
                        }
                    }
                }
            } footer: {
                Text("As the default browser, the app opens links from other apps in the profile chosen by the rules below. Hold ⌥ while clicking a link to choose the profile.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach($settings.linkRules) { $rule in
                    RuleRow(rule: $rule, profiles: controller.knownProfiles, detected: controller.detectedProfiles,
                            onMove: move, onDelete: delete)
                }
                Button {
                    settings.linkRules.append(LinkRule(pattern: "", profile: controller.knownProfiles.first ?? ""))
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
            } header: {
                Text("Rules (the first match wins)")
            } footer: {
                Text("example.com includes subdomains, *.example.com only subdomains, github.com/org a path. The app is a bundle id, e.g. com.tinyspeck.slackmacgap; empty means any app. Rules also pick the profile for “Move tab to the other profile”.")
                    .foregroundStyle(.secondary)
            }
            Section("Other links") {
                Picker("Open in", selection: $settings.defaultLinkProfile) {
                    Text("Ask").tag("")
                    ForEach(controller.knownProfiles, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Remove tracking parameters (utm_*, fbclid, …)", isOn: $settings.stripTrackingParams)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Unwrap redirect links (Outlook Safe Links, Facebook, Google, VK)", isOn: $settings.unwrapRedirects)
                    Text("Safe Links are checked by Microsoft when clicked; unwrapped links skip that check.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Try a link") {
                TextField("Link", text: $testLink, prompt: Text(verbatim: "https://github.com/org/repo"))
                TextField("From app", text: $testApp, prompt: Text(verbatim: "com.apple.mail"))
                Text(testResult).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var testResult: String {
        guard let url = URL(string: testLink.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            return String(localized: "Enter a link with http:// or https://")
        }
        let cleaned = LinkCleaner.clean(
            url, unwrapRedirects: settings.unwrapRedirects, stripTracking: settings.stripTrackingParams)
        let app = testApp.trimmingCharacters(in: .whitespaces)
        let profile = controller.linkProfile(for: cleaned, sourceApp: app.isEmpty ? nil : app)
        let target = profile.map { String(localized: "Opens in “\($0)”") } ?? String(localized: "Asks for a profile")
        return cleaned == url ? target : "\(target): \(cleaned.absoluteString)"
    }

    private func move(_ rule: LinkRule, by offset: Int) {
        guard let index = settings.linkRules.firstIndex(of: rule),
              settings.linkRules.indices.contains(index + offset)
        else { return }
        settings.linkRules.swapAt(index, index + offset)
    }

    private func delete(_ rule: LinkRule) {
        settings.linkRules.removeAll { $0.id == rule.id }
    }
}

private struct RuleRow: View {
    @Binding var rule: LinkRule
    let profiles: [String]
    let detected: [String]
    let onMove: (LinkRule, Int) -> Void
    let onDelete: (LinkRule) -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("Site", text: $rule.pattern, prompt: Text(verbatim: "example.com"))
                .labelsHidden()
            TextField("App", text: $rule.sourceApp, prompt: Text("any app"))
                .labelsHidden()
                .frame(width: 130)
            Menu {
                ForEach(runningApps, id: \.self) { bundleID in
                    Button(bundleID) { rule.sourceApp = bundleID }
                }
            } label: {
                Image(systemName: "app.badge")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick a running app")
            Picker("Profile", selection: $rule.profile) {
                if !profiles.contains(rule.profile) { Text(rule.profile).tag(rule.profile) }
                ForEach(profiles, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            if !detected.isEmpty && !rule.profile.isEmpty && !detected.contains(rule.profile) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help(ProfileWarning.missingProfile(rule.profile).message)
            }
            Button { onMove(rule, -1) } label: { Image(systemName: "chevron.up") }
            Button { onMove(rule, 1) } label: { Image(systemName: "chevron.down") }
            Button { onDelete(rule) } label: { Image(systemName: "trash") }
        }
        .buttonStyle(.borderless)
    }

    private var runningApps: [String] {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier))
            .sorted()
    }
}
