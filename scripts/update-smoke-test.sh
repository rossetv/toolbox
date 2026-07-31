#!/bin/bash
# Dev-only manual check — NOT a GATES.md gate. It refuses to run at all when its OWN install
# target (~/Applications/Toolbox.app) already exists, or when any Toolbox process is already
# running (see preflight below) — both machine-dependent by design: a check that goes red
# because the developer's own copy of the app happens to be open is a flaky gate, not a
# useful one. Run it by hand when touching the updater/relaunch path; it is not part of
# `xcodebuild test` or CI.
#
# Spec §11's EMPIRICAL relaunch verification: a dev build dir hits the degrade-to-release-page
# path by design (it isn't installed under an Applications folder), so proving the REAL
# aside-swap + relaunch mechanism needs a genuine install. This script:
#   1. builds a Debug Toolbox.app and installs a copy at ~/Applications/Toolbox.app (v0.1.0)
#   2. builds a second copy bumped to a fixture version, packages it into a DMG, and serves
#      that DMG plus a fixture "latest release" feed from a local HTTP server
#   3. launches the installed app with TOOLBOX_SMOKE=update + TOOLBOX_UPDATE_FEED set — the
#      DEBUG-only hooks in UpdateSmoke.swift/UpdateChecker.swift run the REAL SelfUpdater
#      flow (download/checksum/mount/install/relaunch) against that fixture, never live GitHub
#   4. asserts: the old process actually exited, the on-disk bundle was actually swapped to
#      the new version, and the relaunched instance actually ran and self-identified
#
# Never touches live GitHub and never writes anywhere but ~/Applications (see preflight).
set -euo pipefail
cd "$(dirname "$0")/.."

NEW_VERSION="9.9.9"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/Toolbox.app"
STATE_DIR="$HOME/Library/Caches/com.toolbox.app"
MARKER="$STATE_DIR/update-smoke.marker"
RESULT_LOG="$STATE_DIR/update-smoke-result.log"

fail() { echo "STOP: $*" >&2; exit 1; }

# --- Preflight: never touch a real install or a running copy --------------------------
# The two hard stops below are scoped to what this script can actually put at risk: its own
# install target, and any live Toolbox process (this script's launches, or a real one, would
# be indistinguishable to yieldToExistingInstance's bundle-ID-wide check).
[ -e "$INSTALLED_APP" ] && fail "$INSTALLED_APP already exists — refusing to overwrite a real install."
if pgrep -f "Toolbox\.app/Contents/MacOS/Toolbox" >/dev/null 2>&1; then
    fail "a Toolbox process is already running — refusing to run the smoke test."
fi
# /Applications/Toolbox.app is logged, never a stop condition: this script only ever writes
# to $INSTALLED_APP above, and the relaunch helper's `exec open "$2"` (SelfUpdater's
# relaunchArguments, pinned by testRelaunchArgumentsPassThePathAsAnArgumentNotAsShellText)
# resolves by the ABSOLUTE PATH it is given, never by bundle ID — verified empirically with a
# throwaway two-copy probe (open <path> launched exactly that copy, not the other one sharing
# its bundle identifier). A real install at /Applications is therefore untargeted by
# construction and is left exactly as found.
if [ -e "/Applications/Toolbox.app" ]; then
    echo "==> NOTE: /Applications/Toolbox.app exists (a real install) — not targeted by this script, left untouched."
fi
command -v python3 >/dev/null || fail "python3 is required to serve the fixture feed"

WORK="$(mktemp -d)"
SERVER_PID=""
MOUNT=""
CREATED_INSTALL_DIR=0
cleanup() {
    set +e
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null
    for v in /Volumes/Toolbox*; do
        [ -d "$v" ] && hdiutil detach "$v" -quiet 2>/dev/null
    done
    rm -rf "$INSTALLED_APP"
    rm -rf "$INSTALL_DIR"/.Toolbox-*.staged.app "$INSTALL_DIR"/.Toolbox-*.aside.app
    if [ "$CREATED_INSTALL_DIR" = "1" ] && [ -d "$INSTALL_DIR" ] && [ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        rmdir "$INSTALL_DIR"
    fi
    rm -f "$MARKER" "$RESULT_LOG"
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- Build Debug into a scratch DerivedData, away from the repo's own build/ -----------
echo "==> Generating project"
xcodegen generate
echo "==> Building Debug"
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug \
    -derivedDataPath "$WORK/build" build > "$WORK/build.log" 2>&1 \
    || { tail -80 "$WORK/build.log" >&2; fail "Debug build failed — see log above"; }
DEBUG_APP="$WORK/build/Build/Products/Debug/Toolbox.app"
[ -d "$DEBUG_APP" ] || fail "no Debug app produced at $DEBUG_APP"

OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEBUG_APP/Contents/Info.plist")"
[ "$OLD_VERSION" != "$NEW_VERSION" ] || fail "fixture NEW_VERSION ($NEW_VERSION) must differ from the Debug build's own version"
echo "==> Debug build is v$OLD_VERSION"

# --- Install the "old" copy ------------------------------------------------------------
[ -d "$INSTALL_DIR" ] || CREATED_INSTALL_DIR=1
mkdir -p "$INSTALL_DIR"
ditto "$DEBUG_APP" "$INSTALLED_APP"
echo "==> Installed old copy at $INSTALLED_APP"

# --- Build the "new" copy: same app, bumped version, re-signed ------------------------
# codesign --force re-seals the bundle after PlistBuddy invalidates the existing signature by
# editing Info.plist — an unsigned/invalid-signature app can fail to launch via `open` at all,
# which would surface as "the relaunch is broken" against perfectly good relaunch code.
#
# NO --options runtime here, unlike package-dmg.sh: that script signs a RELEASE build, which
# has no separate dylib to go out of sync with. A Debug build carries loose sibling dylibs
# next to the main executable (Xcode's debug-dylib indirection for faster incremental builds,
# plus the SwiftUI Previews stub) — Xcode's OWN Debug build deliberately signs this
# combination ad-hoc WITHOUT hardened runtime ("Disabling hardened runtime with ad-hoc
# codesigning", seen in its build output) precisely because hardened runtime's library
# validation cannot vouch for an ad-hoc-signed dylib loaded by a separately-signed ad-hoc
# executable ("different Team IDs", surfaced as `Library not loaded` at launch). Forcing
# runtime back on when re-signing reproduces exactly that failure — discovered empirically
# the first two times this script ran end to end. Matching Xcode's own choice for THIS
# configuration is the fix, not a workaround.
#
# Nested code first, then the outer bundle (same ordering package-dmg.sh uses for gs, same
# reason: an out-of-date nested signature is what the outer bundle's fresh reseal cannot fix).
# `--deep` is deliberately avoided, as elsewhere in this repo: it can silently re-sign nested
# code with options that don't match what was just applied here, so each nested Mach-O is
# signed explicitly instead.
NEW_PAYLOAD="$WORK/new-payload"
mkdir -p "$NEW_PAYLOAD"
NEW_APP="$NEW_PAYLOAD/Toolbox.app"
ditto "$DEBUG_APP" "$NEW_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$NEW_APP/Contents/Info.plist"
for nested in "$NEW_APP/Contents/Resources/ghostscript/bin/gs" \
              "$NEW_APP/Contents/MacOS/Toolbox.debug.dylib" \
              "$NEW_APP/Contents/MacOS/__preview.dylib"; do
    [ -f "$nested" ] && codesign --force --timestamp=none --sign - "$nested"
done
codesign --force --timestamp=none --sign - "$NEW_APP"
codesign --verify --deep --strict --verbose=2 "$NEW_APP"
echo "==> Fixture payload re-signed as v$NEW_VERSION"

# --- Package it into a fixture DMG + checksum ------------------------------------------
DMG="$WORK/Toolbox.dmg"
hdiutil create -volname Toolbox -srcfolder "$NEW_PAYLOAD" -ov -format UDZO -quiet "$DMG"
shasum -a 256 "$DMG" | awk '{print $1"  Toolbox.dmg"}' > "$DMG.sha256"

FEED_DIR="$WORK/feed"
mkdir -p "$FEED_DIR"
cp "$DMG" "$FEED_DIR/Toolbox.dmg"
cp "$DMG.sha256" "$FEED_DIR/Toolbox.dmg.sha256"

# --- Serve it over loopback HTTP (never live GitHub) ------------------------------------
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$FEED_DIR" > "$WORK/http.log" 2>&1 &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 50); do
    # `|| true`: under `pipefail`, grep finding no match yet (the server hasn't written its
    # startup line) makes the whole pipeline exit non-zero, which `set -e` would otherwise
    # treat as this assignment statement failing and abort the script on the very first poll.
    PORT="$(grep -o 'port [0-9]*' "$WORK/http.log" 2>/dev/null | head -1 | awk '{print $2}')" || true
    [ -n "$PORT" ] && break
    sleep 0.1
done
[ -n "$PORT" ] || fail "fixture HTTP server never reported its port"
echo "==> Fixture server on 127.0.0.1:$PORT"

# html_url is stored (Release.pageURL) but never fetched — a well-formed placeholder is fine
# and is NOT a live GitHub call. dmgURL points at the loopback fixture: parseRelease's
# DEBUG-only carve-out (pinnedDMGURL) accepts it only because TOOLBOX_UPDATE_FEED is set.
cat > "$FEED_DIR/feed.json" <<JSON
{"tag_name": "v${NEW_VERSION}", "html_url": "https://github.com/rossetv/toolbox/releases/tag/v${NEW_VERSION}", "assets": [{"browser_download_url": "http://127.0.0.1:${PORT}/Toolbox.dmg"}]}
JSON

# --- Drive the old process directly (captures its stdout) ------------------------------
OLD_LOG="$WORK/old-process.log"
TOOLBOX_SMOKE=update TOOLBOX_UPDATE_FEED="http://127.0.0.1:${PORT}/feed.json" \
    "$INSTALLED_APP/Contents/MacOS/Toolbox" > "$OLD_LOG" 2>&1 &
OLD_PID=$!
echo "==> Old process running as PID $OLD_PID — waiting for it to exit…"

# `wait` both blocks until it exits AND reaps it. The relaunch helper polls `kill -0` on this
# same PID; an unreaped (zombied) process still answers `kill -0` successfully, so the helper
# would spin forever waiting for a process that has, from a script's-eye view, already
# finished — `wait` is what actually removes it from the process table.
# `|| true`: a non-zero exit (or the process dying to a signal) must not trip `set -e` here —
# that would abort the script before OLD_EXIT is captured and before the log below is ever
# read, turning a diagnosable failure into an opaque "the script just stopped".
OLD_EXIT=0
wait "$OLD_PID" || OLD_EXIT=$?

echo "--- old process output ---"
cat "$OLD_LOG"
echo "--------------------------"

grep -q "UPDATE-SMOKE PASS" "$OLD_LOG" || fail "old process did not report UPDATE-SMOKE PASS (exit $OLD_EXIT)"
if kill -0 "$OLD_PID" 2>/dev/null; then fail "old process $OLD_PID is somehow still alive after wait"; fi
echo "==> Old process $OLD_PID confirmed exited"

# --- Assert the bundle on disk was actually swapped -------------------------------------
SWAPPED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist")"
[ "$SWAPPED_VERSION" = "$NEW_VERSION" ] || fail "installed bundle is v$SWAPPED_VERSION, expected v$NEW_VERSION"
echo "==> Installed bundle confirmed swapped to v$SWAPPED_VERSION"

# --- Assert the relaunched instance actually ran and self-identified -------------------
# The relaunched process is launched by the helper's `open` call, whose stdout this script
# cannot see — UpdateSmoke.checkRelaunchIfMarked() writes its confirmation to RESULT_LOG
# instead, which is the load-bearing evidence that the relaunch genuinely happened (stronger
# than a process-table sighting: it proves the new process ran AND read its own version).
DEADLINE=$((SECONDS + 30))
until [ -s "$RESULT_LOG" ] || [ "$SECONDS" -ge "$DEADLINE" ]; do sleep 0.2; done
[ -s "$RESULT_LOG" ] || fail "the relaunched instance never wrote its result log within 30s"
echo "--- relaunch result ---"
cat "$RESULT_LOG"
echo "-----------------------"
grep -q "UPDATE-SMOKE RELAUNCHED" "$RESULT_LOG" || fail "relaunched instance did not confirm the new version"

# The relaunched instance exits itself (checkRelaunchIfMarked calls exit()) — but give it a
# moment and clean up defensively so nothing lingers after this script exits.
sleep 1
pkill -f "Toolbox\.app/Contents/MacOS/Toolbox" 2>/dev/null || true

echo "==> PASS: old PID $OLD_PID exited, bundle swapped v$OLD_VERSION -> v$SWAPPED_VERSION, relaunch confirmed"
