#!/bin/bash
# Toolbox
# Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# One-line installer: downloads the latest Toolbox DMG from GitHub Releases,
# copies the app to /Applications (or ~/Applications if that isn't writable),
# removes the quarantine attribute (the app isn't notarised yet) and launches it.
#
#   curl -fsSL https://raw.githubusercontent.com/rossetv/toolbox/main/scripts/install.sh | bash
#
# Deliberately boring: no sudo, fails loud, cleans up after itself.
set -euo pipefail

REPO="rossetv/toolbox"
VOLUME="/Volumes/Toolbox"

fail() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Toolbox is a macOS app."
[ "$(uname -m)" = "arm64" ] || fail "Toolbox requires Apple Silicon."
macos_major=$(sw_vers -productVersion | cut -d. -f1)
[ "$macos_major" -ge 14 ] || fail "Toolbox requires macOS 14 or later (you have $(sw_vers -productVersion))."

echo "Finding the latest release…"
dmg_url=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" |
    grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | cut -d'"' -f4)
[ -n "$dmg_url" ] || fail "no DMG found in the latest release — see https://github.com/${REPO}/releases"

workdir=$(mktemp -d)
trap 'hdiutil detach "$VOLUME" -quiet 2>/dev/null || true; rm -rf "$workdir"' EXIT

echo "Downloading $(basename "$dmg_url")…"
curl -fL --progress-bar -o "$workdir/Toolbox.dmg" "$dmg_url"

hdiutil detach "$VOLUME" -quiet 2>/dev/null || true
hdiutil attach "$workdir/Toolbox.dmg" -nobrowse -quiet
[ -d "$VOLUME/Toolbox.app" ] || fail "the DMG did not contain Toolbox.app"

dest="/Applications"
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
echo "Installing to $dest…"
rm -rf "${dest:?}/Toolbox.app"
ditto "$VOLUME/Toolbox.app" "$dest/Toolbox.app"
hdiutil detach "$VOLUME" -quiet

# The app isn't notarised yet; without this, Gatekeeper blocks the first launch.
xattr -dr com.apple.quarantine "$dest/Toolbox.app"

echo "Done — launching Toolbox."
open "$dest/Toolbox.app"
