import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            #if SELF_TEST
            // Built in debug, or with `scripts/build-app.sh --self-test`; not part of the release app.
            if CommandLine.arguments.contains("--self-test") {
                SelfTest.run()
            }
            #endif
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var statusMenu: StatusMenu!
    private var settingsWindow: SettingsWindowController?

    /// The link handler has to be in place before launch finishes: the link that launched the app arrives then.
    func applicationWillFinishLaunching(_ notification: Notification) {
        controller = AppController()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        statusMenu = StatusMenu(controller: controller) { [weak self] in self?.showSettings() }
    }

    /// A link opened in another app while this app is the default browser.
    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text)
        else { return }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        let sourceApp = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        controller.openLink(url, sourceApp: sourceApp, forceChoice: NSEvent.modifierFlags.contains(.option))
    }

    /// HTML files opened with this app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            controller.openLink(url, sourceApp: nil, forceChoice: NSEvent.modifierFlags.contains(.option))
        }
    }

    /// Launching the app again (e.g. from Finder) opens the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(controller: controller)
        }
        settingsWindow?.show()
    }

    /// Shown while the settings window is open (the app is a regular one then); gives it ⌘W, ⌘Q and copy/paste.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = app

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = window
        return main
    }
}
