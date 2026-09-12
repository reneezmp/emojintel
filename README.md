# ☀️ Emojintel

Sonoma-style smart emoji suggestions for macOS Ventura.

Type a word → tap `fn` → a pill appears at the word → Enter replaces it with an emoji.
Native Swift, no dependencies, no network at runtime, menu-bar only.

Built for **Rosy** (MacBook10,1, Ventura 13.7.8), the last macOS this machine officially runs.

## Status

**Working.** Confirmed on Ventura 13.7.8 in Notes, TextEdit, Stickies, Mail, Messages,
Reminders, Finder, Spotlight, System Settings, Safari (address bar and page fields),
Terminal, Discord, Edge, Osaurus, Claude for Desktop, and Electron apps generally.

## Install

```bash
make cert       # one-time: self-signed identity so the Accessibility grant survives rebuilds
make install    # build, sign, copy to /Applications, launch
```

Then grant Accessibility when prompted, and set
System Settings → Keyboard → "Press fn key to" → **Do Nothing**.
(The app detects it if you don't, and says so in its ☀️ menu rather than failing silently.)

Type a word, tap `fn` — or **Right ⌘** — then `←` `→` to choose, Enter to accept,
`1`–`3` to jump straight to one, Esc to dismiss. The chevron, `↓`, or a second `fn` tap
opens the full emoji picker at the caret, the way Sonoma's does.
Command-key shortcuts pass through without dismissing the pill, so `⌘⇧4` can screenshot it.

## Custom words

☀️ menu → **Edit Custom Words…** pins your own word → emoji pairs, up to three emoji each.
They rank ahead of both the bundled tuning and generic scoring, and apply on the next `fn`
tap without a relaunch. Deleting one falls straight back to standard behaviour.

They live in `~/Library/Application Support/Emojintel/user-words.json`, deliberately not in
the app bundle: the bundle is code-signed and the Accessibility grant is pinned to that
signature, so writing inside it would break the seal and silently revoke the grant — the
exact failure `make cert` exists to prevent. It also means pins survive `make install`,
which does `rm -rf` on the bundle. The file uses the same shape as `overrides.json`, so a
pin that turns out to be generally right rather than personal can be promoted by copying
the line across. A pinned emoji doesn't have to be in the bundled index at all — 🕊️ isn't,
and pins it fine.

## What was hard

macOS documentation is wrong or absent for most of this, so every design decision below
came from probing the machine rather than from the docs. The probes are still in the repo
(`make run-keys`, `run-ax`, `run-focus`, `run-markers`, `rank`) because they earned it.

**`fn` doesn't emit key events.** It emits `flagsChanged` with keycode 63 — modifier keys
never produce keyDown/keyUp. A tap masking `keyDown|keyUp` never fires at all. Also: plain
arrow keys carry `maskSecondaryFn` on Mac laptops, so you must gate on the keycode, never
on the flag.

**The AX constants don't exist.** `AXAttributeConstants.h` in the Command Line Tools SDK is
documentation-only — zero `#define`s — and `kAXBoundsForRangeParameterizedAttribute`
appears nowhere in the SDK. Every attribute name here is a string literal.

**`AXUIElementCreateSystemWide()` is useless on this machine.** It returns `cannotComplete`
for `AXFocusedUIElement` in every app. The per-application element built from the frontmost
pid is the primary route.

**Roles lie; capabilities don't.** Whitelisting `AXTextField`/`AXTextArea` misses custom
controls and web content. Elements are selected by whether they actually expose a usable
selection range.

**Never read the whole field.** Terminal's `AXValue` is its entire scrollback — 758 KB in
testing. Text is read through a ±96-character `AXStringForRange` window instead.

**Never do AX work inside the event-tap callback.** The first AX call into an app costs
22–354 ms. A slow callback trips `kCGEventTapDisabledByTimeout` and the tap dies silently.
The callback runs the keycode state machine and nothing else.

**Some apps lie about writes.** Safari's fields and Electron text areas return `.success`
from setting `AXSelectedTextRange` without applying it. The selection is always set, read
back, and only believed if it matches.

**Terminals lie differently.** Their `AXTextArea` is the scrollback, not the input line —
setting a selection succeeds, but typed characters go to the tty, so the emoji lands beside
the word instead of replacing it. Terminals skip AX writes entirely.

**Electron returns a fake rect,** `(0, 800, 0x0)`, rather than failing. Caret rects are
validated for size and on-screen-ness, not merely non-nil.

**A bundle-ID allowlist silently excludes every app you didn't think of.** Chromium exposes
nothing over AX until `AXManualAccessibility` is set on the app element, and the gate for
that was once a hardcoded list of bundle IDs. Any Electron app missing from it failed at
the very first step, logging a line indistinguishable from "there's no text field here" —
Claude for Desktop racked up 35 consecutive `no focused element` before this was found.
Chromium is now detected structurally, by what the bundle actually ships, and neither
obvious marker suffices alone: Electron and CEF put `Helper (Renderer).app` at the top of
`Contents/Frameworks`, while Chrome, Edge and ChatGPT bury their helpers inside
`<Name> Framework.framework` under a version directory and name them inconsistently —
those are identified by Chromium's ANGLE/SwiftShader dylibs instead. The union of both
markers catches all of them and still rejects Safari, Notes, Finder and Terminal. One more
wrinkle: the tree is built *asynchronously* after the flag is set, so the tap that switches
it on generally finds nothing and the next one works. The log says so when that happens.

**An invisible menu bar is load-bearing.** `LSUIElement` apps never display a menu bar, so
it's tempting to skip `NSApp.mainMenu` entirely — but AppKit still routes key equivalents
through it, and without an Edit menu `⌘V` does nothing in a text field. Pasting is the main
way an emoji reaches the custom-words editor, so the app builds a menu nobody can see.

**The Character Viewer reports nothing back.** `orderFrontCharacterPalette` has no delegate,
no completion handler and no notification — it inserts into the first responder and tells
the app nothing. So "choose an emoji for this row" can't be implemented as a picker that
returns a value; it's implemented as aiming the insertion at the right field, selecting its
contents first so the pick replaces rather than appends. The editor's emoji cells filter
typed text live for the same reason: the field must stay editable for the palette to reach
it, which otherwise leaves it open to someone typing a word into it.

**...and it opens in the *calling* app's context, which for a menu-bar app is nowhere.**
`orderFrontCharacterPalette` from the pill appears to work — the picker opens — but every
emoji picked lands nowhere, because the palette belongs to Emojintel, an accessory app with
no focused text field. The identical call works perfectly from the custom-words editor,
where we really are the active app with a field focused; whether it works depends entirely
on who is frontmost. Opening the picker *for the app you're typing in* means synthesizing
the system-wide "Show Emoji & Symbols" shortcut (⌃⌘Space) instead, so that app opens its
own picker at its own caret. That shortcut is symbolic hotkey 179, and it can be switched
off in System Settings — an absent plist entry means the default, which is on, so only an
explicit `enabled = 0` counts as off. The ☀️ menu says so when it is.

**Mail needs a completely different API.** Its compose area is an `AXWebArea` with no
`AXSelectedTextRange` at all; WebKit uses opaque text markers
(`AXLeftWordTextMarkerRangeForTextMarker` and friends). Markers can't be written, so
replacement there is by synthesized keystrokes.

**Ad-hoc signing quietly breaks everything.** `codesign --sign -` pins the TCC record to the
binary's cdhash, so every rebuild revokes Accessibility with no re-prompt. `make cert`
creates a stable self-signed identity. Two surprises: `security import` fails MAC
verification on a PKCS12 with an *empty* password, and the certificate does **not** need to
be trusted — `codesign` signs fine with an untrusted one and still produces the
`identifier + certificate leaf` requirement that makes the grant survive.

**`.nonactivatingPanel` only works on `NSPanel`.** `NSWindow.h` says so in a comment and
nowhere else; on a plain `NSWindow` the flag is silently ignored and the pill steals focus
from the app you're typing in, which defeats the entire point.

**`layer.cornerRadius` doesn't clip an `NSVisualEffectView`.** The effect view manages its
own layer, so the corners render square no matter what radius you set. `maskImage` with cap
insets is the approach that works. Same shape of bug as the `AXSelectedTextRange` one: an
API that accepts a value, reports success, and quietly does nothing.

**Emojibase's ranking is Unicode chart order, not frequency,** so `fire` ranks ❤️‍🔥 above 🔥
and `love` ranks 💌 above ❤️. `Resources/overrides.json` pins the 85 words where that
matters.

## The probes

These need Accessibility permission, and when run from a terminal that permission belongs
to *the terminal app*, not to the probe. Run them from Terminal.app and grant it when
prompted.

```
make check          # fn setting, Secure Input, Accessibility trust
make run-keys       # log keyDown / flagsChanged; verify the fn and Right-⌘ triggers
make run-ax         # focused element: role, read path, word, caret rect, timing
make run-focus      # why focused-element lookup failed, with exact AXErrors
make run-markers    # every AX attribute + the WebKit text-marker chain
make rank WORDS="…" # the emoji index and ranking, without launching the app
```

The app also writes one line per trigger to `~/Library/Logs/Emojintel.log`
(☀️ menu → Open Diagnostics Log).

## Layout

```
Makefile                      build · sign · install
Tools/build-index.py          Emojibase (pinned v17.0.0) → slim bundled index
Tools/make-signing-cert.sh    one-time self-signed identity, so TCC survives rebuilds
Tools/make-icons.swift        the app icon: ☀️ on rose gold, rendered not hand-drawn
Resources/emoji-index.json    1716 emoji, 203 KB, generated
Resources/overrides.json      85 hand-curated words where generic ranking gets it wrong
Sources/Emojintel/            the app
Sources/Shared/               AX plumbing and the emoji index, shared with the probes
Sources/emojintel-probe/      diagnostics, kept permanently as a debugging aid
```

Two things are generated rather than committed. `Resources/emoji-index.json` **is** in the
repo, because rebuilding it needs the network and the build must not. `Emojintel.icns` is
**not**, because `make icons` regenerates it offline in a second — and a 1.1 MB binary in
git is how the first push failed.

## Make targets

```
make install     # the usual one: build, sign, install to /Applications, launch
make app         # build the bundle without installing
make icons       # regenerate the app icon (edit Tools/make-icons.swift to retune it)
make index       # regenerate the emoji index from Emojibase (needs network)
make cert        # one-time signing identity
make uninstall   # remove /Applications/Emojintel.app
make clean       # drop .build/
```

## Notes

- **SwiftPM does not work here.** `swift build` fails with `xcrun: unable to lookup item
  'PlatformPath'` because only Command Line Tools are installed. The Makefile drives
  `swiftc` directly; with zero third-party packages nothing is lost.
- **Sign with a stable identity, not ad-hoc.** `codesign --sign -` pins TCC to the
  binary's cdhash, so every rebuild silently revokes Accessibility with no re-prompt.
  `make cert` creates a self-signed "Emojintel Dev" identity once; the grant then survives
  rebuilds. Two non-obvious details, both verified in an isolated keychain:
  `security import` fails MAC verification on a PKCS12 with an *empty* password, and the
  certificate does **not** need to be trusted — codesign signs fine with an untrusted
  self-signed identity and still produces an `identifier + certificate leaf` designated
  requirement, which is exactly what makes the grant survive. So there is no
  `add-trusted-cert` step. `security find-identity -v` will report 0 valid identities;
  that is cosmetic, drop the `-v`.
- Emoji data from [Emojibase](https://github.com/milesj/emojibase) (MIT), bundled offline.
