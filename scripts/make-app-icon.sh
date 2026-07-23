#!/usr/bin/env bash
# Toolbox
# Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regenerates Resources/AppIcon.icns from scripts/make-app-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
swiftc -O scripts/make-app-icon.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/AppIcon.iconset"
mkdir -p Resources
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns ($(stat -f%z Resources/AppIcon.icns) bytes)"
