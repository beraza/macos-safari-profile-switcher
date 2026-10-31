import AppKit
import SwitcherCore

/// Links from other apps while this app is the default browser.
extension AppController {
    /// Where a link from another app goes: a rule's profile or app, the default profile (or
    /// `AppSettings.safariDecides`), or `nil` to ask.
    func linkTarget(for url: URL, sourceApp: String?) -> LinkTarget? {
        RuleMatcher.target(for: url, sourceApp: sourceApp, rules: settings.linkRules)
            ?? (settings.defaultLinkProfile.isEmpty ? nil : .profile(settings.defaultLinkProfile))
    }

    /// Opens a link from another app in the profile its rules pick; asks when none does or ⌥ is held.
    func openLink(_ url: URL, sourceApp: String?, forceChoice: Bool = false) {
        let url = url.isFileURL ? url : LinkCleaner.clean(
            url, unwrapRedirects: settings.unwrapRedirects, stripTracking: settings.stripTrackingParams)
        log.info("link \(url.absoluteString, privacy: .private) from \(sourceApp ?? "?", privacy: .public)")
        if !forceChoice, let target = linkTarget(for: url, sourceApp: sourceApp) {
            switch target {
            case .profile(AppSettings.safariDecides):
                // Safari applies its own Settings → Websites → "Open links in profile" to links from other apps.
                openInSafari(url)
            case .profile(let profile):
                route(url, to: profile)
            case .app(let bundleID, _):
                open(target.url(for: url), inApp: bundleID, fallback: url)
            }
        } else {
            chooseProfile(for: url)
        }
    }

    /// Queued like the shortcut actions (and never dropped), so links clicked in a row each get their window.
    private func route(_ url: URL, to profile: String) {
        enqueue({ controller in
            try await controller.launchSafariIfNeeded()
            let windows = try SafariController.windows()
            if let window = windows.first(where: { controller.profile(of: $0) == profile }) {
                try SafariController.openTab(url: url.absoluteString, windowID: window.id)
                try SafariController.focus(windowID: window.id)
            } else {
                let id = try await controller.openNewWindow(profile: profile, replacing: nil)
                try SafariController.setCurrentTabURL(url.absoluteString, windowID: id)
            }
            SafariController.runningApp?.activate()
        }, onError: { [weak self] error in
            // Never lose a link: let Safari open it the usual way.
            let name = ProfileMatcher.displayName(profile)
            self?.fail(String(localized: "Couldn't open the link in “\(name)”: \(error.localizedDescription)"))
            self?.openInSafari(url)
        })
    }

    /// Opens a link in another app (as the rule rewrote it); if that fails, the original link goes to Safari.
    private func open(_ url: URL, inApp bundleID: String, fallback: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            fail(String(localized: "App \(bundleID) not found"))
            openInSafari(fallback)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) {
            [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.fail(error.localizedDescription)
                self?.openInSafari(fallback)
            }
        }
    }

    func openInSafari(_ url: URL) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.bundleID) else {
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A menu at the mouse pointer with the profiles; hold ⌥ to also remember the choice for the host.
    private func chooseProfile(for url: URL) {
        let menu = NSMenu()
        let header = NSMenuItem(title: Self.shortened(url.absoluteString), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let host = url.host()
        for profile in knownProfiles {
            let name = ProfileMatcher.displayName(profile)
            menu.addItem(ClosureMenuItem(title: name) { [weak self] in self?.route(url, to: profile) })
            if let host {
                let remember = ClosureMenuItem(title: String(localized: "\(name) — always for \(host)")) { [weak self] in
                    self?.settings.remember(host: host, profile: profile)
                    self?.route(url, to: profile)
                }
                remember.isAlternate = true
                remember.keyEquivalentModifierMask = .option
                menu.addItem(remember)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Open in Safari (its website settings decide)")) { [weak self] in
            self?.openInSafari(url)
        })
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func shortened(_ text: String) -> String {
        text.count > 70 ? text.prefix(69) + "…" : text
    }

    /// Launches Safari in the background and waits until it answers AppleScript.
    func launchSafariIfNeeded() async throws {
        guard SafariController.runningApp == nil else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.bundleID) else {
            throw AppError(String(localized: "Safari not found"))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if (try? SafariController.windows()) != nil { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SafariError.timeout
    }

    /// Whether this app opens http(s) links.
    var isDefaultBrowser: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Makes this app (or Safari again) the default browser; macOS asks the user to confirm.
    func setDefaultBrowser(_ enabled: Bool) {
        let app = enabled ? Bundle.main.bundleURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariController.bundleID)
        guard let app else { return }
        Task {
            do {
                for scheme in ["http", "https"] {
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
                }
                try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html)
            } catch {
                fail(error.localizedDescription)
            }
            objectWillChange.send()
        }
    }
}
