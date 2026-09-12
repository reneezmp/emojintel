import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var coordinator: Coordinator?
    private var index: EmojiIndex?
    private var trustTimer: Timer?
    private var wordEditor: WordEditorController?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)          // menu-bar only, no Dock icon
        installEditMenu()
        Diagnostics.rotateIfLarge()
        Diagnostics.log("── Emojintel launched ──")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.toolTip = "Emojintel"
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

    /// An accessory app never displays a menu bar — but NSApplication still routes key
    /// equivalents through `NSApp.mainMenu`, and without an Edit menu ⌘V does nothing in a
    /// text field. Pasting is the main way an emoji gets into the custom-words editor, so
    /// the invisible menu is load-bearing. Selectors are by name because the responder is
    /// the field editor, not any particular class.
    private func installEditMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Emojintel",
                                 action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo",   action: Selector(("undo:")),   keyEquivalent: "z")
        edit.addItem(withTitle: "Redo",   action: Selector(("redo:")),   keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut",    action: #selector(NSText.cut(_:)),    keyEquivalent: "x")
        edit.addItem(withTitle: "Copy",   action: #selector(NSText.copy(_:)),   keyEquivalent: "c")
        edit.addItem(withTitle: "Paste",  action: #selector(NSText.paste(_:)),  keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
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
        if !Permissions.emojiHotkeyEnabled {
            menu.addItem(item("⚠︎ “Show Emoji & Symbols” shortcut is off — ↓ can't open the picker…",
                              #selector(openKeyboard)))
        }
        if !Permissions.isTrusted || !Permissions.fnIsFree || Permissions.secureInputActive
            || !Permissions.emojiHotkeyEnabled {
            menu.addItem(.separator())
        }

        if coordinator != nil {
            menu.addItem(item(running ? "Pause Emojintel" : "Resume Emojintel", #selector(togglePause)))
        }
        if let index {
            let info = NSMenuItem(title: "\(index.count) emoji · \(index.overrideCount) tuned"
                                       + " · \(index.userWordCount) custom",
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(item("Edit Custom Words…", #selector(editWords)))
        menu.addItem(.separator())
        menu.addItem(item("Open Diagnostics Log", #selector(openLog)))
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

    @objc private func editWords() {
        if wordEditor == nil {
            let editor = WordEditorController()
            editor.onChange = { [weak self] in
                self?.index?.reloadUserWords()   // live: the next fn tap sees the edit
                self?.rebuildMenu()
            }
            wordEditor = editor
        }
        wordEditor?.show()
    }

    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openKeyboard()      { Permissions.openKeyboardSettings() }
    @objc private func quit()              { NSApp.terminate(nil) }
    @objc private func openLog() {
        let url = Diagnostics.url
        if !FileManager.default.fileExists(atPath: url.path) {
            Diagnostics.log("(log opened before any trigger)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSWorkspace.shared.open(url)
        }
    }

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
