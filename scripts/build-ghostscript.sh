#!/usr/bin/env bash
# PDF Toolbox
# Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# This file is part of PDF Toolbox, released under the GNU Affero General
# Public License v3.0 or later. See the LICENSE file in the project root.
#
# Reproducible Ghostscript build (spike-proven). Builds 10.07.1 for arm64 as a
# single ~26 MB binary that links only /usr/lib system dylibs (freetype/jpeg/png/…
# statically linked in, Resource tree embedded in ROM), into Resources/ghostscript/.
# Idempotent: skips the build if a matching binary is already present. Run locally
# and in CI before building the app. The binary is git-ignored (never committed).

set -euo pipefail

GS_VERSION="10.07.1"
GS_TAG="gs10071"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/Resources/ghostscript"
GS_BIN="${DEST}/bin/gs"

if [[ -x "${GS_BIN}" ]] && env -i "${GS_BIN}" --version 2>/dev/null | grep -q "${GS_VERSION}"; then
  echo "gs ${GS_VERSION} already present at ${GS_BIN} — skipping build."
  exit 0
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
cd "${BUILD_DIR}"

# Pinned source digest. This is the SHA-256 of the tarball this project actually built and
# verified (the resulting gs links only system dylibs, runs under a scrubbed environment, and
# compresses correctly). Pinning it means a later build cannot silently pick up a substituted
# or corrupted archive: the bundled binary is shipped inside the app, so an unverified download
# here would be a supply-chain hole straight into the release. If you deliberately move to a new
# Ghostscript version, update GS_VERSION/GS_TAG and this digest together, ideally cross-checked
# against Artifex's own published checksum for that release.
GS_SHA256="1cdb766de8db8f1e589c817f09c5855ea5f65dfc8540e465a69ac14c18416025"

echo "Fetching Ghostscript ${GS_VERSION} source…"
curl -fSL --retry 3 --retry-delay 2 -o gs.tar.xz \
  "https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/${GS_TAG}/ghostscript-${GS_VERSION}.tar.xz"

echo "Verifying source digest…"
ACTUAL_SHA256="$(shasum -a 256 gs.tar.xz | awk '{print $1}')"
if [[ "${ACTUAL_SHA256}" != "${GS_SHA256}" ]]; then
  echo "ERROR: Ghostscript source digest mismatch — refusing to build." >&2
  echo "  expected ${GS_SHA256}" >&2
  echo "  actual   ${ACTUAL_SHA256}" >&2
  exit 1
fi

tar xf gs.tar.xz
cd "ghostscript-${GS_VERSION}"

# Two env knobs, both MANDATORY:
#   MACOSX_DEPLOYMENT_TARGET=14.0 — stamp minos 14.0 so the binary runs on the app's floor.
#   PKG_CONFIG_LIBDIR/PATH blinded to system-only — stop configure grabbing Homebrew dylibs
#   (forces the bundled freetype/jpeg/png/… so the result is system-dylibs-only).
echo "Configuring…"
env MACOSX_DEPLOYMENT_TARGET=14.0 PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig PKG_CONFIG_PATH= \
  ./configure \
    --prefix="${PWD}/../install" \
    --disable-fontconfig \
    --disable-dbus \
    --disable-cups \
    --without-tesseract \
    --without-x

echo "Building (plain make — statically links libgs into the executable)…"
env MACOSX_DEPLOYMENT_TARGET=14.0 PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig PKG_CONFIG_PATH= \
  make -j"$(sysctl -n hw.ncpu)"

mkdir -p "${DEST}/bin"
cp bin/gs "${GS_BIN}"
chmod +x "${GS_BIN}"

echo "Built gs → ${GS_BIN}"
env -i "${GS_BIN}" --version

echo "Dependency check (expect only /usr/lib and /System dylibs)…"
DEPS="$(otool -L "${GS_BIN}" | tail -n +2 | awk '{print $1}')"
echo "${DEPS}"
BAD_DEPS="$(echo "${DEPS}" | grep -Ev '^(/usr/lib/|/System/)' || true)"
if [[ -n "${BAD_DEPS}" ]]; then
  echo "ERROR: gs links non-system dylibs — this build is not portable (likely Homebrew-linked):" >&2
  echo "${BAD_DEPS}" >&2
  exit 1
fi
echo "OK: only system dylibs linked."
