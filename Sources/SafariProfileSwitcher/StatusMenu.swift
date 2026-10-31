import AppKit
import Combine
import SwitcherCore

/// The menu bar item: shows the active profile and, when opened, Safari's windows grouped by profile.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    init(controller: AppController, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        let settings = controller.settings
        Publishers.Merge3(
            controller.$currentProfile.map { _ in () },
            settings.$showProfileIndicator.map { _ in () },
            settings.$profileBadges.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.updateButton() }
        .store(in: &cancellables)
        updateButton()
    }

    // MARK: - Button

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let settings = controller.settings
        if settings.showProfileIndicator, let profile = controller.currentProfile {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: settings.badge(for: profile),
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)])
            button.toolTip = profile
        } else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Safari Profile Switcher")
            button.toolTip = "Safari Profile Switcher"
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = controller.settings
        let windows = SafariController.runningApp == nil ? nil : Result { try SafariController.windows() }
        controller.updateProfileWarnings(windows: try? windows?.get())
        menu.addItem(disabled(controller.profilesSummary))
        if let shortcut = settings.shortcuts[.switchProfile] {
            menu.addItem(disabled(String(localized: "Shortcut: \(shortcut.displayString)")))
        }
        if let error = controller.lastError {
            menu.addItem(disabled("⚠️ \(error)"))
        }
        for warning in controller.profileWarnings {
            menu.addItem(disabled("⚠️ \(warning.message)"))
        }
        menu.addItem(.separator())
        addWindows(windows, to: menu)
        if let transfer = controller.lastTransfer {
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "Always open \(transfer.host) in “\(transfer.profile)”")) {
                $0.rememberLastTransfer()
            })
        }
        menu.addItem(.separator())
        let settingsItem = item(String(localized: "Settings…")) { [weak self] _ in self?.openSettings() }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        let quit = NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Windows grouped by profile (known profiles first, in order), each with a "New Window" item.
    private func addWindows(_ result: Result<[SafariWindow], Error>?, to menu: NSMenu) {
        guard let result else {
            menu.addItem(disabled(String(localized: "Safari is not running")))
            return
        }
        let windows: [SafariWindow]
        do {
            windows = try result.get()
        } catch {
            menu.addItem(disabled("⚠️ \(error.localizedDescription)"))
            return
        }
        let profiles = controller.knownProfiles
        let groups = WindowGroups.make(windows: windows, profiles: profiles)
        for group in groups {
            menu.addItem(.sectionHeader(title: group.profile ?? String(localized: "Other windows")))
            for window in group.windows {
                let title = ProfileMatcher.pageTitle(ofTitle: window.title, profile: group.profile)
                let menuItem = item(Self.truncate(title.isEmpty ? String(localized: "Start Page") : title)) {
                    $0.showWindow(id: window.id)
                }
                if window.tabCount > 1 { menuItem.badge = NSMenuItemBadge(count: window.tabCount) }
                if window.id == windows.first?.id { menuItem.state = .on }
                menuItem.toolTip = window.title
                menu.addItem(menuItem)
            }
            if let profile = group.profile {
                let newWindow = item(String(localized: "New Window")) { $0.openWindow(profile: profile) }
                newWindow.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
                menu.addItem(newWindow)
            }
        }
    }

    /// Builds the menu as if it were opened and returns its lines (self-test).
    func renderedLines() -> [String] {
        menuNeedsUpdate(menu)
        return menu.items.map { item in
            if item.isSeparatorItem { return "———" }
            if item.isSectionHeader { return "[\(item.title)]" }
            let badge = item.badge.map { " (\($0.itemCount))" } ?? ""
            return "\(item.state == .on ? "✓ " : "  ")\(item.title)\(badge)"
        }
    }

    private static func truncate(_ title: String) -> String {
        title.count > 60 ? title.prefix(59) + "…" : title
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, action: @escaping (AppController) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title) { [weak controller] in
            if let controller { action(controller) }
        }
        return item
    }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
