# Emojintel — built with swiftc directly.
#
# NOTE: SwiftPM does not work on this machine. `swift build` fails with
#   "xcrun: error: unable to lookup item 'PlatformPath'"
# because only Command Line Tools are installed (no full Xcode). swiftc has no such
# dependency, and with zero third-party packages we lose nothing by skipping SwiftPM.

APP        := Emojintel
BUNDLE_ID  := dev.renee.emojintel
IDENTITY   := Emojintel Dev
BUILD      := .build
APPDIR     := $(BUILD)/$(APP).app
INSTALLDIR := /Applications/$(APP).app

SWIFTFLAGS := -O -target x86_64-apple-macos13.0
SHARED_SRC := $(wildcard Sources/Shared/*.swift)
APP_SRC    := $(wildcard Sources/Emojintel/*.swift) $(SHARED_SRC)
PROBE_SRC  := $(wildcard Sources/emojintel-probe/*.swift) $(SHARED_SRC)

.PHONY: all probe app install uninstall index cert clean run-keys run-ax run-focus run-markers rank check

all: app

## Phase 0 diagnostics
probe: $(BUILD)/emojintel-probe

$(BUILD)/emojintel-probe: $(PROBE_SRC)
	@mkdir -p $(BUILD)
	swiftc $(SWIFTFLAGS) -o $@ $(PROBE_SRC)
	@echo "✓ $@"

run-keys: probe
	./$(BUILD)/emojintel-probe keys

run-ax: probe
	./$(BUILD)/emojintel-probe ax

run-focus: probe
	./$(BUILD)/emojintel-probe focus

run-markers: probe
	./$(BUILD)/emojintel-probe markers

rank: probe
	./$(BUILD)/emojintel-probe rank

check: probe
	./$(BUILD)/emojintel-probe env

## The app bundle
app: $(APPDIR)

$(APPDIR): $(APP_SRC) Resources/emoji-index.json Resources/overrides.json Resources/Info.plist
	@mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Resources
	swiftc $(SWIFTFLAGS) -o $(APPDIR)/Contents/MacOS/$(APP) $(APP_SRC)
	cp Resources/Info.plist        $(APPDIR)/Contents/Info.plist
	cp Resources/emoji-index.json  $(APPDIR)/Contents/Resources/
	cp Resources/overrides.json    $(APPDIR)/Contents/Resources/
	cp Resources/EMOJIBASE-LICENSE $(APPDIR)/Contents/Resources/
	@touch $(APPDIR)
	@echo "✓ $(APPDIR)"

## Install to the STABLE path. TCC keys on path as well as signature, so granting
## Accessibility to a build-directory copy and then moving it re-breaks the grant.
install: app
	@if ! security find-identity -p codesigning | grep -q "$(IDENTITY)"; then \
		echo "✗ No '$(IDENTITY)' signing identity. Run: make cert"; exit 1; fi
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf $(INSTALLDIR)
	cp -R $(APPDIR) $(INSTALLDIR)
	codesign --force --options runtime --sign "$(IDENTITY)" $(INSTALLDIR)
	@echo "--- designated requirement (must stay identical across rebuilds) ---"
	@codesign -d -r- $(INSTALLDIR) 2>&1 | tail -1
	@echo "✓ installed to $(INSTALLDIR)"
	open $(INSTALLDIR)

uninstall:
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf $(INSTALLDIR)
	@echo "✓ removed $(INSTALLDIR)  (the Accessibility entry stays; remove it in System Settings)"

cert:
	./Tools/make-signing-cert.sh "$(IDENTITY)"

## Regenerate the bundled emoji index from Emojibase (needs network; output is committed)
index:
	python3 Tools/build-index.py

clean:
	rm -rf $(BUILD)
