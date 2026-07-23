#!/usr/bin/env bash
# PDF Toolbox
# Copyright (C) 2026 PDF Toolbox authors
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# This file is part of PDF Toolbox, released under the GNU Affero General
# Public License v3.0 or later. See the LICENSE file in the project root.
#
# Reproducible Leptonica build. Builds 1.87.0 (BSD-2-Clause) for arm64 as a
# STATIC library plus headers into Resources/native/leptonica/. Leptonica supplies
# the binarisation and segmentation primitives the scan-compression pipeline needs
# (Otsu/Sauvola thresholding, connected components, MRC layer separation); unlike
# Ghostscript it is linked into our own code rather than exec'd, so a static archive
# is the right shape — nothing to bundle, nothing to resolve at runtime.
#
# Every image codec is disabled on purpose: we hand Leptonica pixel buffers from
# CoreGraphics and take pixel buffers back, so libpng/libjpeg/libtiff/giflib/webp/
# openjpeg would be dead weight AND the only realistic route to a Homebrew dylib
# creeping into the app. Leptonica compiles error-returning stubs in their place,
# so anything that references them still links.
#
# Idempotent: skips the build when a matching archive is already present. Run
# locally and in CI before building the app. Output is git-ignored (never committed).
#
# Build-time requirements: Xcode Command Line Tools only (clang, make). Leptonica's
# release tarball ships a pre-generated `configure` and its own `config/ltmain.sh`,
# so no autoconf/automake/libtool/cmake/pkg-config is needed.

set -euo pipefail

LEPT_VERSION="1.87.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/Resources/native/leptonica"
LEPT_LIB="${DEST}/lib/libleptonica.a"
LEPT_HDR="${DEST}/include/leptonica/allheaders.h"

# Idempotency: the archive exists AND its headers declare the version we pin. Checking
# the headers too means a stale build of a different version cannot masquerade as this one.
# (The LIBLEPT_*_VERSION macros live in allheaders.h, not environ.h.)
lept_header_version() {
  [[ -f "${LEPT_HDR}" ]] || return 1
  local major minor patch
  major="$(awk '/^#define[[:space:]]+LIBLEPT_MAJOR_VERSION/ {print $3}' "${LEPT_HDR}")"
  minor="$(awk '/^#define[[:space:]]+LIBLEPT_MINOR_VERSION/ {print $3}' "${LEPT_HDR}")"
  patch="$(awk '/^#define[[:space:]]+LIBLEPT_PATCH_VERSION/ {print $3}' "${LEPT_HDR}")"
  echo "${major}.${minor}.${patch}"
}

if [[ -f "${LEPT_LIB}" ]] && [[ "$(lept_header_version || true)" == "${LEPT_VERSION}" ]]; then
  echo "leptonica ${LEPT_VERSION} already present at ${LEPT_LIB} — skipping build."
  exit 0
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
cd "${BUILD_DIR}"

# Pinned source digest of the upstream release asset. The resulting archive is linked
# straight into the shipped app, so an unverified download here would be a supply-chain
# hole into the release. Fail closed on mismatch. Moving to a new Leptonica version means
# updating LEPT_VERSION and this digest together, cross-checked against the upstream
# release page — never bumping the digest to whatever the download happened to be.
LEPT_SHA256="c73363397f96eb1295602bf44d708a994ad42046c791bf03ea0505d829bdb6a7"

echo "Fetching Leptonica ${LEPT_VERSION} source…"
curl -fSL --retry 3 --retry-delay 2 -o leptonica.tar.gz \
  "https://github.com/DanBloomberg/leptonica/releases/download/${LEPT_VERSION}/leptonica-${LEPT_VERSION}.tar.gz"

echo "Verifying source digest…"
ACTUAL_SHA256="$(shasum -a 256 leptonica.tar.gz | awk '{print $1}')"
if [[ "${ACTUAL_SHA256}" != "${LEPT_SHA256}" ]]; then
  echo "ERROR: Leptonica source digest mismatch — refusing to build." >&2
  echo "  expected ${LEPT_SHA256}" >&2
  echo "  actual   ${ACTUAL_SHA256}" >&2
  exit 1
fi

tar xzf leptonica.tar.gz
cd "leptonica-${LEPT_VERSION}"

# Two env knobs, both MANDATORY — same pair as the Ghostscript build:
#   MACOSX_DEPLOYMENT_TARGET=14.0 — stamps every object in the archive with minos 14.0,
#   the app's floor. A .a records the build version per object file, so setting this only
#   at the app's link step is too late.
#   PKG_CONFIG_LIBDIR/PATH blinded to system-only — stops configure discovering Homebrew's
#   libpng/libjpeg/… and linking dylibs that exist on this machine and on no user's.
echo "Configuring (static only, every image codec disabled)…"
env MACOSX_DEPLOYMENT_TARGET=14.0 PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig PKG_CONFIG_PATH= \
  ./configure \
    --prefix="${BUILD_DIR}/install" \
    --disable-shared \
    --enable-static \
    --disable-programs \
    --disable-dependency-tracking \
    --without-zlib \
    --without-libpng \
    --without-jpeg \
    --without-giflib \
    --without-libtiff \
    --without-libwebp \
    --without-libwebpmux \
    --without-libopenjpeg

echo "Building…"
env MACOSX_DEPLOYMENT_TARGET=14.0 PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig PKG_CONFIG_PATH= \
  make -j"$(sysctl -n hw.ncpu)"

env MACOSX_DEPLOYMENT_TARGET=14.0 make install

BUILT_LIB="${BUILD_DIR}/install/lib/libleptonica.a"
if [[ ! -f "${BUILT_LIB}" ]]; then
  echo "ERROR: expected static archive not found at ${BUILT_LIB}" >&2
  echo "  (built libraries: $(ls "${BUILD_DIR}/install/lib" 2>/dev/null | tr '\n' ' '))" >&2
  exit 1
fi

# Replace wholesale rather than merging into whatever was there before — a half-updated
# tree of headers from one version and an archive from another is the worst outcome.
rm -rf "${DEST}"
mkdir -p "${DEST}"
cp -R "${BUILD_DIR}/install/include" "${DEST}/include"
mkdir -p "${DEST}/lib"
cp "${BUILT_LIB}" "${LEPT_LIB}"
# BSD-2-Clause obliges us to reproduce the copyright notice when distributing in
# binary form, and this archive is linked into the app — stage it for packaging.
cp "leptonica-license.txt" "${DEST}/LICENSE-leptonica.txt"

echo "Built leptonica ${LEPT_VERSION} → ${LEPT_LIB}"
echo "Architecture check (expect arm64):"
lipo -archs "${LEPT_LIB}"
