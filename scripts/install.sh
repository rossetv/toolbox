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
# Deliberately boring: no sudo, fails loud, cleans up after itself. The whole body
# lives in main(), invoked on the last line, so a connection that drops mid-download
# can never execute a truncated script.
set -euo pipefail

REPO="rossetv/toolbox"

fail() { echo "error: $*" >&2; exit 1; }

main() {
    [ "$(uname -s)" = "Darwin" ] || fail "Toolbox is a macOS app."
    [ "$(uname -m)" = "arm64" ] || fail "Toolbox requires Apple Silicon."
    local macos_major
    macos_major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$macos_major" -ge 14 ] || fail "Toolbox requires macOS 14 or later (you have $(sw_vers -productVersion))."

    echo "Finding the latest release…"
    local dmg_url
    dmg_url=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" |
        grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | cut -d'"' -f4)
    [ -n "$dmg_url" ] || fail "no DMG found in the latest release — see https://github.com/${REPO}/releases"

    local workdir mount=""
    workdir=$(mktemp -d)
    # shellcheck disable=SC2064 — expand workdir now; mount is re-read at trap time via the file.
    trap '[ -s "$workdir/mount" ] && hdiutil detach "$(cat "$workdir/mount")" -quiet 2>/dev/null; rm -rf "$workdir"' EXIT

    echo "Downloading $(basename "$dmg_url")…"
    curl -fL --progress-bar -o "$workdir/Toolbox.dmg" "$dmg_url"

    # Ask hdiutil where it actually mounted the volume rather than assuming a name:
    # a busy /Volumes/Toolbox would otherwise silently become "/Volumes/Toolbox 1".
    # Parsed with sed alone — a stock Mac has no developer tools to lean on.
    mount=$(hdiutil attach "$workdir/Toolbox.dmg" -nobrowse -plist |
        grep -A1 '<key>mount-point</key>' |
        sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | head -1)
    [ -n "$mount" ] || fail "could not mount the DMG"
    printf '%s' "$mount" > "$workdir/mount"
    [ -d "$mount/Toolbox.app" ] || fail "the DMG did not contain Toolbox.app"

    local dest="/Applications"
    [ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
    echo "Installing to $dest…"
    rm -rf "${dest:?}/Toolbox.app"
    ditto "$mount/Toolbox.app" "$dest/Toolbox.app"

    # The app isn't notarised yet; without this, Gatekeeper blocks the first launch.
    xattr -dr com.apple.quarantine "$dest/Toolbox.app"

    # Best-effort: Spotlight can hold the volume busy for a moment; the EXIT trap retries,
    # and a still-mounted volume must not fail an install that has already succeeded.
    hdiutil detach "$mount" -quiet 2>/dev/null || true

    echo "Done — launching Toolbox."
    open "$dest/Toolbox.app"
}

main "$@"
