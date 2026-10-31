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
                Text("example.com includes subdomains, *.example.com only subdomains, github.com/org a path. “From” is the app the link is clicked in, as a bundle id (e.g. com.tinyspeck.slackmacgap); empty means any app. A rule can also open links in another app, such as a video call app: if the app takes its own scheme instead of https (Kontur Talk: ktalk), set it next to the app. Profile rules also pick the profile for “Move tab to the next profile”.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Open in", selection: $settings.defaultLinkProfile) {
                    Text("Safari decides (its website settings)").tag(AppSettings.safariDecides)
                    Text("Ask").tag("")
                    ForEach(controller.knownProfiles, id: \.self) { Text(ProfileMatcher.displayName($0)).tag($0) }
                }
                Toggle("Remove tracking parameters (utm_*, fbclid, …)", isOn: $settings.stripTrackingParams)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Unwrap redirect links (Outlook Safe Links, Facebook, Google, VK)", isOn: $settings.unwrapRedirects)
                    Text("Safe Links are checked by Microsoft when clicked; unwrapped links skip that check.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Other links")
            } footer: {
                Text("“Safari decides” passes the link to Safari, which applies Safari Settings → Websites → Open Links in Profile (or uses the most recent profile). Keep plain per-site choices there, and rules here for what Safari can't do: the source app, paths, a profile menu, cleaning links.")
                    .foregroundStyle(.secondary)
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
        let linkTarget = controller.linkTarget(for: cleaned, sourceApp: app.isEmpty ? nil : app)
        let opened = linkTarget?.url(for: cleaned) ?? cleaned
        let target = switch linkTarget {
        case nil: String(localized: "Asks for a profile")
        case .profile(AppSettings.safariDecides)?: String(localized: "Safari decides by its website settings")
        case .profile(let profile)?: String(localized: "Opens in “\(ProfileMatcher.displayName(profile))”")
        case .app(let bundleID, _)?: String(localized: "Opens in the app “\(AppInfo.name(of: bundleID))”")
        }
        return opened == url ? target : "\(target): \(opened.absoluteString)"
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

    /// Tag of the "Other app…" item, which asks for an app.
    private static let chooseApp = "#choose-app"
    private static let appPrefix = "app:"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Site", text: $rule.pattern, prompt: Text(verbatim: "example.com"))
                    .labelsHidden()
                Text("from").foregroundStyle(.secondary)
                TextField("From app", text: $rule.sourceApp, prompt: Text("any app"))
                    .labelsHidden()
                    .frame(width: 150)
                    .help("Bundle id of the app the link is clicked in; empty means any app")
                Menu {
                    ForEach(runningApps, id: \.self) { bundleID in
                        Button("\(AppInfo.name(of: bundleID)) — \(bundleID)") { rule.sourceApp = bundleID }
                    }
                } label: {
                    Image(systemName: "app.badge")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pick a running app")
                Button { onMove(rule, -1) } label: { Image(systemName: "chevron.up") }
                Button { onMove(rule, 1) } label: { Image(systemName: "chevron.down") }
                Button { onDelete(rule) } label: { Image(systemName: "trash") }
            }
            HStack(spacing: 6) {
                Text("open in").foregroundStyle(.secondary)
                Picker("Open in", selection: target) {
                    if rule.targetApp.isEmpty && !profiles.contains(rule.profile) {
                        Text(rule.profile).tag(rule.profile)
                    }
                    ForEach(profiles, id: \.self) { Text(ProfileMatcher.displayName($0)).tag($0) }
                    Divider()
                    if !rule.targetApp.isEmpty {
                        Text("App “\(AppInfo.name(of: rule.targetApp))”").tag(Self.appPrefix + rule.targetApp)
                    }
                    Text("Other app…").tag(Self.chooseApp)
                }
                .labelsHidden()
                .fixedSize()
                if !rule.targetApp.isEmpty {
                    TextField("Scheme", text: $rule.targetScheme, prompt: Text(verbatim: "https"))
                        .labelsHidden()
                        .frame(width: 70)
                        .help("The app's own link scheme: https://… becomes scheme://…; empty passes the link as it is")
                    Text("://").foregroundStyle(.secondary)
                }
                if rule.targetApp.isEmpty && !detected.isEmpty && !rule.profile.isEmpty
                    && rule.profile != ProfileMatcher.privateProfile && !detected.contains(rule.profile) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        .help(ProfileWarning.missingProfile(rule.profile).message)
                }
                Spacer()
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }

    /// The profile, or the app as "app:<bundle id>".
    private var target: Binding<String> {
        Binding(
            get: { rule.targetApp.isEmpty ? rule.profile : Self.appPrefix + rule.targetApp },
            set: { value in
                if value == Self.chooseApp {
                    chooseTargetApp()
                } else if !value.hasPrefix(Self.appPrefix) {
                    rule.profile = value
                    rule.targetApp = ""
                    rule.targetScheme = ""
                }
            })
    }

    private func chooseTargetApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = String(localized: "Choose the app to open these links in")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        rule.targetApp = bundleID
        rule.targetScheme = AppInfo.linkScheme(of: url) ?? ""
    }

    private var runningApps: [String] {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier))
            .sorted()
    }
}

/// Names and link schemes of installed apps.
enum AppInfo {
    static func name(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The scheme to pass web links to the app with: `nil` if it opens https links itself, else the first
    /// scheme it registers (e.g. `ktalk` for Kontur Talk, which takes ktalk://host/room for https://host/room).
    static func linkScheme(of app: URL) -> String? {
        let opensWeb = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .contains { $0.standardizedFileURL == app.standardizedFileURL }
        guard !opensWeb,
              let types = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        else { return nil }
        return types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .first { !["http", "https", "file"].contains($0.lowercased()) }
    }
}
