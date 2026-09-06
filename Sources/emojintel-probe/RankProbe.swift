import Foundation

/// Checks the bundled index and ranking without launching the app.
///   emojintel-probe rank            → run the regression words
///   emojintel-probe rank fire love  → look up specific words
enum RankProbe {

    static func run(words: [String]) {
        let res = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
        guard let index = EmojiIndex(resourceDirectory: res) else {
            print("✗ could not load Resources/emoji-index.json — run `make index`")
            return
        }
        print("loaded \(index.count) emoji, \(index.overrideCount) tuned words\n")

        if !words.isEmpty {
            for w in words { show(index, w) }
            return
        }

        // Words the generic scoring got wrong in Phase 0, plus a control group.
        print("── regressions (these were wrong before overrides.json) ──")
        for w in ["fire", "love", "sad", "cat", "happy", "cry", "hot", "cold"] { show(index, w) }
        print("\n── control (generic scoring already correct) ──")
        for w in ["party", "phone", "pizza", "rocket", "thinking", "ghost", "pink", "heart"] {
            show(index, w)
        }
        print("\n── should return nothing ──")
        for w in ["asdfgh", "the", "xyzzy"] { show(index, w) }
    }

    private static func show(_ index: EmojiIndex, _ word: String) {
        let hits = index.suggestions(for: word, limit: 3)
        let emoji = hits.isEmpty ? "(none)" : hits.map(\.emoji).joined(separator: " ")
        let labels = hits.map(\.label).joined(separator: ", ")
        print("  \(word.padding(toLength: 10, withPad: " ", startingAt: 0)) → \(emoji)   \(labels)")
    }
}
