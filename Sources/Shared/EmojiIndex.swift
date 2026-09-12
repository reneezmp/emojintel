import Foundation

struct EmojiHit {
    let emoji: String
    let label: String
}

/// Word → emoji lookup over the bundled Emojibase index.
///
/// Emojibase's `order` field is Unicode *chart* order, not frequency, so pure scoring
/// puts obscure variants first for exactly the words people type most: `fire` ranks
/// ❤️‍🔥 above 🔥, `love` ranks 💌 above ❤️, `sad` ranks "sad but relieved face" first.
/// `overrides.json` pins the handful of words where that matters; everything else falls
/// through to normal scoring.
final class EmojiIndex {

    /// How many suggestions the pill shows. Lives here because two places depend on it and
    /// must agree: the coordinator asks for this many, and the custom-words editor refuses
    /// to store more than this many per word — anything beyond it could never be displayed.
    static let maxSuggestions = 3

    private struct Entry: Decodable {
        let e: String        // emoji
        let l: String        // label
        let t: [String]      // tags
        let s: [String]      // shortcodes
        let o: Int           // emojibase order
    }

    private var entries: [Entry] = []
    private var byKeyword: [String: [(idx: Int, score: Int)]] = [:]
    private var overrides: [String: [String]] = [:]
    private var userWords: [String: [String]] = [:]
    private var labelFor: [String: String] = [:]

    /// Function words appear inside emoji labels ("rolling on THE floor laughing",
    /// "face WITH tears of joy"), so a bare token match makes them return nonsense.
    /// Nobody wants an emoji for "the" — these return nothing at all.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "of", "at", "by", "for", "with",
        "to", "from", "in", "on", "off", "out", "up", "is", "it", "its", "as", "be",
        "am", "are", "was", "were", "been", "this", "that", "these", "those", "then",
        "than", "so", "too", "very", "can", "will", "just", "not", "no", "my", "me",
        "you", "your", "he", "she", "they", "them", "we", "us", "i",
    ]

    private enum Score {
        static let exactLabel = 100, exactShortcode = 90, exactTag = 80
        static let prefixLabel = 60, prefixOther = 40
    }

    init?(resourceDirectory: URL) {
        guard let data = try? Data(contentsOf: resourceDirectory.appendingPathComponent("emoji-index.json")),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return nil }
        entries = decoded
        buildIndex()

        if let od = try? Data(contentsOf: resourceDirectory.appendingPathComponent("overrides.json")),
           let raw = try? JSONSerialization.jsonObject(with: od) as? [String: Any] {
            for (k, v) in raw where !k.hasPrefix("_") {
                if let list = v as? [String] { overrides[k.lowercased()] = list }
            }
        }
        userWords = UserWords.load()
    }

    /// Re-reads the personal list, so edits from the ☀️ menu take effect on the next
    /// trigger rather than on the next launch.
    func reloadUserWords() { userWords = UserWords.load() }

    private func buildIndex() {
        var acc: [String: [Int: Int]] = [:]                 // keyword -> idx -> best score
        func add(_ keyword: String, _ idx: Int, _ score: Int) {
            guard keyword.count >= 2 || score >= Score.exactLabel else { return }
            acc[keyword, default: [:]][idx] = max(acc[keyword, default: [:]][idx] ?? 0, score)
        }

        for (i, e) in entries.enumerated() {
            labelFor[e.e] = e.l
            let labelTokens = e.l.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            for t in labelTokens {
                let s = String(t)
                add(s, i, Score.exactLabel)
                for n in 2..<max(3, s.count) { add(String(s.prefix(n)), i, Score.prefixLabel) }
            }
            for tag in e.t {
                let s = tag.lowercased()
                add(s, i, Score.exactTag)
                for n in 2..<max(3, s.count) { add(String(s.prefix(n)), i, Score.prefixOther) }
            }
            for sc in e.s {
                let s = sc.lowercased().replacingOccurrences(of: "_", with: "")
                add(s, i, Score.exactShortcode)
                for n in 2..<max(3, s.count) { add(String(s.prefix(n)), i, Score.prefixOther) }
            }
        }
        byKeyword = acc.mapValues { $0.map { (idx: $0.key, score: $0.value) } }
    }

    /// Top `limit` suggestions for a typed word.
    func suggestions(for word: String, limit: Int = 3) -> [EmojiHit] {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return [] }
        // Stopwords are skipped unless explicitly pinned ("no" -> ❌). A personal pin counts:
        // deciding "me" should mean 🙋 is exactly the kind of call this list shouldn't veto.
        if Self.stopwords.contains(w), overrides[w] == nil, userWords[w] == nil { return [] }

        var out: [EmojiHit] = []
        var seen = Set<String>()

        // Personal pins first, then the bundled tuning, then generic scoring.
        for emoji in (userWords[w] ?? []) + (overrides[w] ?? []) where !seen.contains(emoji) {
            seen.insert(emoji)
            out.append(EmojiHit(emoji: emoji, label: labelFor[emoji] ?? w))
            if out.count == limit { return out }
        }

        let ranked = (byKeyword[w] ?? [])
            .sorted { $0.score != $1.score ? $0.score > $1.score : entries[$0.idx].o < entries[$1.idx].o }

        for hit in ranked {
            let e = entries[hit.idx]
            guard !seen.contains(e.e) else { continue }
            seen.insert(e.e)
            out.append(EmojiHit(emoji: e.e, label: e.l))
            if out.count == limit { break }
        }
        return out
    }

    var count: Int { entries.count }
    var overrideCount: Int { overrides.count }
    var userWordCount: Int { userWords.count }
}
