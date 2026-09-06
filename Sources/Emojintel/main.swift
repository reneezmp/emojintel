import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var coordinator: Coordinator?
    private var index: EmojiIndex?
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)          // menu-bar only, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "☀️"
        rebuildMenu()

        guard let resources = Bundle.main.resourceURL, let idx = EmojiIndex(resourceDirectory: resources) else {
            fatal("Could not load the bundled emoji index.")
            return
        }
        index = idx

        if Permissions.isTrusted {
            startCoordinator()
        } else {
            Permissions.requestTrust()
            // Poll until granted, then start without needing a relaunch.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                guard Permissions.isTrusted else { return }
                t.invalidate()
                self?.startCoordinator()
            }
        }
    }

    private func startCoordinator() {
        guard let index else { return }
        let c = Coordinator(index: index)
        c.onStateChange = { [weak self] in self?.rebuildMenu() }
        guard c.start() else {
            fatal("Could not install the event tap. Check Accessibility permission.")
            return
        }
        coordinator = c
        rebuildMenu()
    }

    // MARK: - Menu

    @objc private func rebuildMenu() {
        let menu = NSMenu()

        let running = coordinator != nil && !(coordinator?.isPaused ?? true)
        let status = coordinator == nil ? "Waiting for Accessibility…"
                   : (coordinator!.isPaused ? "Paused" : "Active")
        let head = NSMenuItem(title: "Emojintel — \(status)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        if !Permissions.isTrusted {
            menu.addItem(item("⚠︎ Grant Accessibility access…", #selector(openAccessibility)))
        }
        if !Permissions.fnIsFree {
            menu.addItem(item("⚠︎ fn key is set to “\(Permissions.fnUsageDescription)”…",
                              #selector(openKeyboard)))
        }
        if Permissions.secureInputActive {
            let w = NSMenuItem(title: "⚠︎ Secure Input is active — triggers are blocked",
                               action: nil, keyEquivalent: "")
            w.isEnabled = false
            menu.addItem(w)
        }
        if !Permissions.isTrusted || !Permissions.fnIsFree || Permissions.secureInputActive {
            menu.addItem(.separator())
        }

        if coordinator != nil {
            menu.addItem(item(running ? "Pause Emojintel" : "Resume Emojintel", #selector(togglePause)))
        }
        if let index {
            let info = NSMenuItem(title: "\(index.count) emoji · \(index.overrideCount) tuned words",
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Emojintel", #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func togglePause() {
        guard let c = coordinator else { return }
        c.setPaused(!c.isPaused)
    }

    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openKeyboard()      { Permissions.openKeyboardSettings() }
    @objc private func quit()              { NSApp.terminate(nil) }

    private func fatal(_ message: String) {
        let a = NSAlert()
        a.messageText = "Emojintel"
        a.informativeText = message
        a.alertStyle = .critical
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
