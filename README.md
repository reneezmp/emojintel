# ☀️ Emojintel

Sonoma-style smart emoji suggestions for macOS Ventura.

Type a word → tap `fn` → a pill appears at the word → Enter replaces it with an emoji.
Native Swift, no dependencies, no network at runtime, menu-bar only.

Built for **Rosy** (MacBook10,1, Ventura 13.7.8), the last macOS this machine officially runs.

## Status

**Phase 1 — MVP built, awaiting first real-world test.**

### Phase 0 results (measured on Rosy)

| App | element | read path | word | caret rect |
|---|---|---|---|---|
| Notes | AXTextArea | AXStringForRange | ✓ | ✓ |
| Safari (address bar) | AXTextField | AXStringForRange | ✓ | ✓ |
| Osaurus | AXTextArea | AXStringForRange | ✓ | ✓ |
| Claude (Electron) | AXTextArea | AXStringForRange | ✓ | ✗ degenerate → mouse fallback |
| Terminal | AXTextArea | AXStringForRange | ✓ | — (758 KB scrollback, windowed fine) |

Still untested: TextEdit, Mail, Messages, Chrome, VS Code, Safari page fields.

Six findings that changed the design are recorded in the initial commit message.

## Phase 0: run the probes

Both probes need Accessibility permission, and when run from a terminal that permission
belongs to *the terminal app*, not to the probe. Run these from Terminal.app or iTerm and
grant it when prompted.

```
make probe          # build
make check          # report fn setting, Secure Input, Accessibility trust
make run-keys       # verify the fn / Right-⌘ triggers
make run-ax         # dump the focused text element, per app
```

### `run-keys` — what we're proving

The single biggest unknown: **does a lone `fn` reach a userspace event tap on this
machine, and does it still do so while `AppleFnUsageType != 0`?**

Note that `fn` emits `flagsChanged`, *not* `keyDown`/`keyUp` — modifier keys never
generate key events. Watch for keycode 63 appearing as a flagsChanged pair (DOWN then UP)
followed by `FIRE fn tapped alone ✅`.

### `run-ax` — what we're proving

Which apps let us read the word behind the caret, get its on-screen rect, and write a
replacement back. Click through TextEdit, Notes, Safari (address bar *and* a page field),
Mail, Messages, Chrome and VS Code, typing a word in each.

## Layout

```
Makefile                      build · sign · install
Tools/build-index.py          Emojibase (pinned v17.0.0) → slim bundled index
Tools/make-signing-cert.sh    one-time self-signed identity, so TCC survives rebuilds
Resources/emoji-index.json    1716 emoji, 203 KB, generated
Resources/overrides.json      83 hand-curated words where generic ranking gets it wrong
Sources/emojintel-probe/      Phase 0 diagnostics (kept permanently as a debug aid)
Sources/Emojintel/            the app (Phase 1)
```

## Notes

- **SwiftPM does not work here.** `swift build` fails with `xcrun: unable to lookup item
  'PlatformPath'` because only Command Line Tools are installed. The Makefile drives
  `swiftc` directly; with zero third-party packages nothing is lost.
- **Sign with a stable identity, not ad-hoc.** `codesign --sign -` pins TCC to the
  binary's cdhash, so every rebuild silently revokes Accessibility with no re-prompt.
  `make cert` creates a self-signed "Emojintel Dev" identity once; the grant then survives
  rebuilds.
- Emoji data from [Emojibase](https://github.com/milesj/emojibase) (MIT), bundled offline.
