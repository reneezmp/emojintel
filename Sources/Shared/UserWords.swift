import Foundation

/// Personal word → emoji pins, editable from the ☀️ menu.
///
/// These sit *in front of* the bundled `overrides.json`, which in turn sits in front of
/// generic ranking. They never modify the bundled list — a word you pin here wins, and
/// removing it falls straight back to the standard behaviour.
///
/// STORED OUTSIDE THE APP BUNDLE, and that is not a style preference. `/Applications/
/// Emojintel.app` is code-signed, and the Accessibility grant is pinned to that signature
/// (the whole reason `make cert` exists). Writing a file inside the bundle would break the
/// seal and silently revoke the grant — precisely the failure the stable signing identity
/// was introduced to prevent. Application Support is the writable home, and it also
/// survives `make install`, which does `rm -rf` on the bundle.
enum UserWords {

    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Emojintel", isDirectory: true)
    }()

    static let url = directory.appendingPathComponent("user-words.json")

    /// Deliberately the same shape as `overrides.json` — `{"amen": ["🙏"]}` — so a pin that
    /// turns out to be generally right, rather than personal, can be promoted into the
    /// bundled list by copying the line.
    static func load() -> [String: [String]] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var out: [String: [String]] = [:]
        for (key, value) in raw where !key.hasPrefix("_") {
            let word = normalize(key)
            guard !word.isEmpty, let list = value as? [String], !list.isEmpty else { continue }
            out[word] = list
        }
        return out
    }

    @discardableResult
    static func save(_ words: [String: [String]]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: words,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Emojintel: could not save custom words: \(error)")
            return false
        }
    }

    /// Lookup happens on the lowercased word, so pins must be stored the same way or they
    /// would only ever match one capitalisation.
    static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Splits a free-text field into individual emoji, in order.
    ///
    /// Iterating Characters rather than scalars is what keeps 👨‍🦰 and 🇧🇷 in one piece —
    /// a Swift Character is a grapheme cluster, so ZWJ sequences and flags survive. Typing
    /// them run together ("🙏🤲") or spaced ("🙏 🤲") both work. Non-emoji text is dropped,
    /// which is how the editor rejects a word typed into the emoji field.
    static func parseEmoji(_ text: String) -> [String] {
        text.filter { !$0.isWhitespace }.compactMap { character in
            character.unicodeScalars.contains { $0.properties.isEmoji && !$0.isASCII }
                ? String(character) : nil
        }
    }
}
