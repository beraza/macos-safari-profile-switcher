import AppKit
import ApplicationServices

/// Watches Safari through Accessibility notifications: focused window, its title, windows created/minimized.
/// Calls `onChange` (coalesced) so the profile indicator and window list stay current without polling.
@MainActor
final class SafariObserver {
    var onChange: (() -> Void)?

    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var app: AXUIElement?
    /// The focused window; its title changes are observed (they aren't reported for the app element).
    private var observedWindow: AXUIElement?
    private var changePending = false

    private static let appNotifications = [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    var isRunning: Bool { observer != nil }

    /// Starts (or restarts, if Safari was relaunched) observing. Does nothing without Accessibility.
    func start() {
        guard AXIsProcessTrusted(), let safari = SafariController.runningApp else {
            stop()
            return
        }
        guard observer == nil || pid != safari.processIdentifier else { return }
        stop()
        pid = safari.processIdentifier
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<SafariObserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { observer.scheduleChange() }
        }, &created)
        guard status == .success, let created else {
            log.error("AXObserverCreate failed: \(status.rawValue)")
            return
        }
        observer = created
        let app = AXUIElementCreateApplication(pid)
        self.app = app
        for notification in Self.appNotifications {
            AXObserverAddNotification(created, app, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observeFocusedWindowTitle()
        scheduleChange()
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        app = nil
        observedWindow = nil
        pid = 0
    }

    /// Title of Safari's focused window, read via AX (cheap, no Apple Event).
    func focusedWindowTitle() -> String? {
        guard let window = focusedWindow() else { return nil }
        return SafariController.axString(window, kAXTitleAttribute)
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func focusedWindow() -> AXUIElement? {
        guard let app = app ?? SafariController.axApp() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func observeFocusedWindowTitle() {
        guard let observer else { return }
        let window = focusedWindow()
        if let observedWindow, let window, CFEqual(observedWindow, window) { return }
        if let observedWindow {
            AXObserverRemoveNotification(observer, observedWindow, kAXTitleChangedNotification as CFString)
        }
        observedWindow = window
        if let window {
            AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, refcon)
        }
    }

    /// Coalesces bursts of notifications (a page load sends several title changes).
    private func scheduleChange() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changePending = false
                self.observeFocusedWindowTitle()
                self.onChange?()
            }
        }
    }
}
