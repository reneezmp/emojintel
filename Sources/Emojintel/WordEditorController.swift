import AppKit

/// The emoji cell: a display field plus the button that fills it.
///
/// The field stays editable because that is the only way the Character Viewer can deliver
/// anything — the system picker has no "user chose X" callback, it just inserts into the
/// first responder. Typed text is filtered out live (see `controlTextDidChange`), so the
/// field accepts emoji and silently ignores everything else.
private final class EmojiCellView: NSView {
    let field = NSTextField()
    let button = NSButton()

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)

        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.font = .systemFont(ofSize: 16)
        field.placeholderString = "choose…"
        field.lineBreakMode = .byTruncatingTail

        button.title = "Choose…"
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = target
        button.action = action

        for v in [field, button] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -6),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The ☀️ menu's "Edit Custom Words…" window: a table of personal word → emoji pins.
///
/// Deliberately shows *only* the personal list. The 1716-emoji index and the bundled
/// `overrides.json` are not editable here — a pin simply takes precedence over both, and
/// deleting it falls back to standard behaviour with nothing left behind.
///
/// Every edit saves immediately. There is no OK/Cancel, because there is nothing here that
/// needs a transaction: each row is independent, and `onChange` reloads the live index so
/// a new word works on the very next `fn` tap.
final class WordEditorController: NSWindowController, NSTableViewDataSource,
                                  NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {

    private struct Row { var word: String; var emoji: [String] }

    private var rows: [Row] = []
    private let table = NSTableView()

    /// Invoked after every successful save so the running index can pick the change up.
    var onChange: (() -> Void)?

    private enum Column {
        static let word  = NSUserInterfaceItemIdentifier("word")
        static let emoji = NSUserInterfaceItemIdentifier("emoji")
    }
    private static let emojiCellID = NSUserInterfaceItemIdentifier("emojiCell")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Emojintel — Custom Words"
        window.minSize = NSSize(width: 420, height: 220)
        window.setFrameAutosaveName("EmojintelWordEditor")
        window.isReleasedWhenClosed = false      // reopened from the menu; releasing crashes
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Presentation

    func show() {
        reload()
        // An accessory app has no Dock icon, so its window does not come forward on its
        // own — without activating first, this opens behind whatever you were typing in.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing mid-edit must not discard the cell being typed into: resigning first
    /// responder ends editing, which runs the same commit path as tabbing away.
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }

    private func reload() {
        rows = UserWords.load()
            .map { Row(word: $0.key, emoji: $0.value) }
            .sorted { $0.word < $1.word }
        table.reloadData()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        table.dataSource = self
        table.delegate = self
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 28
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let wordCol = NSTableColumn(identifier: Column.word)
        wordCol.title = "Word"
        wordCol.width = 170
        wordCol.minWidth = 90
        table.addTableColumn(wordCol)

        let emojiCol = NSTableColumn(identifier: Column.emoji)
        emojiCol.title = "Emoji"
        emojiCol.minWidth = 140
        table.addTableColumn(emojiCol)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true

        let add    = NSButton(title: "+", target: self, action: #selector(addRow))
        let remove = NSButton(title: "−", target: self, action: #selector(removeSelected))
        for b in [add, remove] { b.bezelStyle = .rounded }

        let hint = NSTextField(labelWithString:
            "Your words come first in the pill. Up to \(EmojiIndex.maxSuggestions) emoji each.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        for v in [scroll, add, remove, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -10),

            add.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            add.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            add.widthAnchor.constraint(equalToConstant: 30),

            remove.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 6),
            remove.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 30),

            hint.leadingAnchor.constraint(equalTo: remove.trailingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, rows.indices.contains(row) else { return nil }

        if id == Column.word {
            let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
                ?? makeWordField()
            field.stringValue = rows[row].word
            return field
        }

        let cell = (tableView.makeView(withIdentifier: Self.emojiCellID, owner: self) as? EmojiCellView)
            ?? makeEmojiCell()
        cell.field.stringValue = rows[row].emoji.joined(separator: " ")
        return cell
    }

    private func makeWordField() -> NSTextField {
        let field = NSTextField()
        field.identifier = Column.word
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.delegate = self
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "word"
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func makeEmojiCell() -> EmojiCellView {
        let cell = EmojiCellView(target: self, action: #selector(chooseEmoji(_:)))
        cell.identifier = Self.emojiCellID
        cell.field.identifier = Column.emoji
        cell.field.delegate = self
        return cell
    }

    // MARK: - Editing

    /// Live filter for the emoji column: typed letters never appear, so the cell can't end
    /// up holding "heart💖". Emoji inserted by the Character Viewer pass through untouched,
    /// up to the number the pill can actually show — the picker stays open after a pick, so
    /// without this you can happily append a fourth that would never be displayed.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field.identifier == Column.emoji,
              let editor = field.currentEditor() else { return }

        let parsed = UserWords.parseEmoji(editor.string)
        let kept = parsed.prefix(EmojiIndex.maxSuggestions).joined(separator: " ")
        guard editor.string != kept else { return }
        if parsed.count > EmojiIndex.maxSuggestions { NSSound.beep() }
        editor.string = kept
        editor.selectedRange = NSRange(location: (kept as NSString).length, length: 0)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        // Resolved through the table rather than a captured index: rows shift under the
        // editor when something is added or deleted, and a stale index writes to the
        // wrong word.
        let row = table.row(for: field)
        guard rows.indices.contains(row) else { return }

        if field.identifier == Column.word {
            commitWord(field.stringValue, at: row, field: field)
        } else {
            commitEmoji(field.stringValue, at: row, field: field)
        }
    }

    private func commitWord(_ raw: String, at row: Int, field: NSTextField) {
        let word = UserWords.normalize(raw)

        // A freshly added row may sit empty until it's filled in. Blanking a real one is
        // rejected instead: an empty word matches nothing and would vanish on save.
        guard !word.isEmpty else {
            if !rows[row].word.isEmpty { NSSound.beep() }
            field.stringValue = rows[row].word
            return
        }
        // The trigger extracts a single word at the caret, so a pin containing a space or
        // punctuation could never fire. Refusing it beats storing one that silently never
        // matches. `isWordChar` is the same predicate the extractor uses.
        guard word.utf16.allSatisfy(isWordChar) else {
            NSSound.beep()
            field.stringValue = rows[row].word
            return
        }
        // Two rows claiming one word would silently collapse into one on save, so the
        // clash is refused and the existing row is selected to show where it went.
        if let clash = rows.firstIndex(where: { $0.word == word }), clash != row {
            NSSound.beep()
            field.stringValue = rows[row].word
            table.selectRowIndexes([clash], byExtendingSelection: false)
            table.scrollRowToVisible(clash)
            return
        }
        rows[row].word = word
        field.stringValue = word        // show the normalisation that was actually stored
        save()
    }

    private func commitEmoji(_ raw: String, at row: Int, field: NSTextField) {
        // Capped again here, not just live: a paste can arrive without a change notification.
        let emoji = Array(UserWords.parseEmoji(raw).prefix(EmojiIndex.maxSuggestions))
        rows[row].emoji = emoji
        field.stringValue = emoji.joined(separator: " ")
        save()
    }

    private func save() {
        var dict: [String: [String]] = [:]
        for r in rows where !r.word.isEmpty && !r.emoji.isEmpty { dict[r.word] = r.emoji }
        UserWords.save(dict)
        onChange?()
    }

    // MARK: - Actions

    /// The Character Viewer inserts into the first responder and reports nothing back, so
    /// "choose an emoji for this row" is really "aim the insertion at this row's field".
    /// Selecting the existing contents first makes the pick replace rather than append.
    @objc private func chooseEmoji(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard rows.indices.contains(row),
              let cell = sender.superview as? EmojiCellView else { return }

        table.selectRowIndexes([row], byExtendingSelection: false)
        window?.makeFirstResponder(cell.field)
        cell.field.currentEditor()?.selectAll(nil)
        NSApp.orderFrontCharacterPalette(nil)
    }

    @objc private func addRow() {
        rows.append(Row(word: "", emoji: []))
        table.reloadData()
        let row = rows.count - 1
        table.scrollRowToVisible(row)
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeSelected() {
        let selected = table.selectedRowIndexes
        guard !selected.isEmpty else { NSSound.beep(); return }
        // Descending, so each removal leaves the remaining indices valid.
        for i in selected.sorted(by: >) where rows.indices.contains(i) { rows.remove(at: i) }
        table.reloadData()
        save()
    }
}
