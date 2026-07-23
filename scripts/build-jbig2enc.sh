#!/usr/bin/env bash
# PDF Toolbox
# Copyright (C) 2026 PDF Toolbox authors
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# This file is part of PDF Toolbox, released under the GNU Affero General
# Public License v3.0 or later. See the LICENSE file in the project root.
#
# Reproducible jbig2enc build. Builds 0.32 (Apache-2.0) for arm64 as a STATIC
# library plus headers into Resources/native/jbig2enc/. jbig2enc is the JBIG2
# encoder for the bilevel scan path: once Leptonica has binarised a page, this
# turns the 1-bpp result into a JBIG2 stream (generic region, or symbol-mode with
# a shared dictionary across pages) far smaller than CCITT G4.
#
# Depends on the Leptonica archive built by scripts/build-leptonica.sh — which this
# script invokes if it is missing, so a single call bootstraps both.
#
# WHY NOT UPSTREAM'S BUILD SYSTEM: jbig2enc offers autotools, CMake and Meson.
# Autotools needs libtoolize, which macOS does not ship (only Homebrew does), and
# both CMake and Meson locate Leptonica through find_package/pkg-config — which on
# any machine with Homebrew can silently resolve to Homebrew's leptonica instead of
# ours, producing exactly the dylib dependency the bundle must not have. The library
# is four .cc files with no generated config.h (proven by upstream's own CMake build,
# which generates none), so compiling them directly against an explicit include path
# and archiving with `ar` is a faithful reproduction of the upstream Release build
# AND makes wrong-leptonica linkage impossible.
#
# Idempotent: skips the build when a matching archive is already present. Run
# locally and in CI before building the app. Output is git-ignored (never committed).
#
# Build-time requirements: Xcode Command Line Tools only (clang++, ar). No autoconf,
# automake, libtool, cmake, meson or pkg-config.

set -euo pipefail

JB2_VERSION="0.32"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/Resources/native/jbig2enc"
JB2_LIB="${DEST}/lib/libjbig2enc.a"
JB2_STAMP="${DEST}/VERSION"

LEPT_DIR="${REPO_ROOT}/Resources/native/leptonica"
LEPT_LIB="${LEPT_DIR}/lib/libleptonica.a"

# Bring Leptonica up to date first — unconditionally, because that script is itself
# idempotent and returns in milliseconds when the archive already matches its pin.
"${REPO_ROOT}/scripts/build-leptonica.sh"

if [[ ! -f "${LEPT_LIB}" ]]; then
  echo "ERROR: ${LEPT_LIB} still missing after running build-leptonica.sh." >&2
  exit 1
fi

# The stamp records the jbig2enc version AND the digest of the exact Leptonica archive
# this build was compiled against, and is written only after a successful build. The
# digest is what makes the skip safe: jbig2enc compiles against Leptonica's internal
# headers (pix_internal.h), so a Leptonica version bump changes struct layout under it.
# Keying the skip on the jbig2enc version alone would silently leave an archive built
# against the old headers linked against the new library.
LEPT_DIGEST="$(shasum -a 256 "${LEPT_LIB}" | awk '{print $1}')"
EXPECTED_STAMP="jbig2enc=${JB2_VERSION} leptonica-archive-sha256=${LEPT_DIGEST}"

if [[ -f "${JB2_LIB}" ]] && [[ -f "${JB2_STAMP}" ]] && [[ "$(cat "${JB2_STAMP}")" == "${EXPECTED_STAMP}" ]]; then
  echo "jbig2enc ${JB2_VERSION} already present at ${JB2_LIB} — skipping build."
  exit 0
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
cd "${BUILD_DIR}"

# Pinned source digest. Fail closed on mismatch — this archive is linked into the
# shipped app, so an unverified download is a supply-chain hole into the release.
#
# CAVEAT specific to this dependency: jbig2enc publishes no source release asset (its
# release assets are Windows binaries), so the source comes from GitHub's auto-generated
# tag archive. Those are produced on demand and their gzip bytes are not contractually
# stable — GitHub has changed them before. A mismatch here is therefore NOT automatically
# an attack, but it is NOT to be papered over with a blind digest bump either: check out
# upstream tag ${JB2_VERSION}, diff the extracted tree against it, and only re-pin once
# the contents are confirmed identical.
JB2_SHA256="5b3b1c48617e5b1608f916a78038ea867a2c9eb20c2ff34a78a48a243f655c2a"

echo "Fetching jbig2enc ${JB2_VERSION} source…"
curl -fSL --retry 3 --retry-delay 2 -o jbig2enc.tar.gz \
  "https://github.com/agl/jbig2enc/archive/refs/tags/${JB2_VERSION}.tar.gz"

echo "Verifying source digest…"
ACTUAL_SHA256="$(shasum -a 256 jbig2enc.tar.gz | awk '{print $1}')"
if [[ "${ACTUAL_SHA256}" != "${JB2_SHA256}" ]]; then
  echo "ERROR: jbig2enc source digest mismatch — refusing to build." >&2
  echo "  expected ${JB2_SHA256}" >&2
  echo "  actual   ${ACTUAL_SHA256}" >&2
  exit 1
fi

tar xzf jbig2enc.tar.gz
SRC="${BUILD_DIR}/jbig2enc-${JB2_VERSION}/src"

# Flags mirror upstream's own Release configuration (CMAKE_CXX_STANDARD 17,
# CMAKE_CXX_FLAGS_RELEASE "-O2 -DNDEBUG", -Wall from Makefile.am, -DVERSION from
# add_definitions). MACOSX_DEPLOYMENT_TARGET stamps every object with minos 14.0 —
# a .a records the build version per object, so setting it at the app's link step
# would be too late.
mkdir -p obj
echo "Compiling jbig2enc ${JB2_VERSION} against ${LEPT_LIB}…"
for unit in jbig2arith jbig2comparator jbig2enc jbig2sym; do
  echo "  CXX ${unit}.cc"
  env MACOSX_DEPLOYMENT_TARGET=14.0 \
    clang++ -std=c++17 -O2 -DNDEBUG -Wall \
      -DVERSION="\"${JB2_VERSION}\"" \
      -I"${LEPT_DIR}/include" \
      -c "${SRC}/${unit}.cc" -o "obj/${unit}.o"
done

ar rcs "${BUILD_DIR}/libjbig2enc.a" obj/jbig2arith.o obj/jbig2comparator.o obj/jbig2enc.o obj/jbig2sym.o

# Replace wholesale — a half-updated tree of headers from one version and an archive
# from another is the worst outcome.
rm -rf "${DEST}"
mkdir -p "${DEST}/lib" "${DEST}/include"
cp "${BUILD_DIR}/libjbig2enc.a" "${JB2_LIB}"
# Same header set upstream installs (include_HEADERS in src/Makefile.am, plus the
# public jbig2enc.h that its CMake install rule ships).
cp "${SRC}/jbig2enc.h" "${SRC}/jbig2arith.h" "${SRC}/jbig2sym.h" \
   "${SRC}/jbig2structs.h" "${SRC}/jbig2segments.h" "${SRC}/jbig2comparator.h" \
   "${DEST}/include/"
# Apache-2.0 §4 obliges us to ship the licence with any distribution of this code,
# and it is linked into the app — so stage it here for the packaging step.
cp "${BUILD_DIR}/jbig2enc-${JB2_VERSION}/COPYING" "${DEST}/LICENSE-jbig2enc.txt"
echo "${EXPECTED_STAMP}" > "${JB2_STAMP}"

echo "Built jbig2enc ${JB2_VERSION} → ${JB2_LIB}"
echo "Architecture check (expect arm64):"
lipo -archs "${JB2_LIB}"
