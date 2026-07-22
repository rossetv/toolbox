# GATES — PDF Toolbox

Claude's runbook for "done" in this repo. A red gate means the work is not done; it does
not mean the gate is wrong. Never make a gate green by editing this file, deleting/skipping
a test, or gutting a script — removing or editing a gate needs a `/panel` + a `DECISIONS.md`
entry. Adding a gate is free.

All commands run from the repo root. macOS 14+, Apple Silicon, Xcode 26.6.

## G1 — Ghostscript builds and runs
```
scripts/build-ghostscript.sh
env -i Resources/ghostscript/bin/gs --version   # must print 10.07.1
```
Green when the script exits 0 and produces a self-contained `Resources/ghostscript/bin/gs`
(`otool -L` shows only `/usr/lib` system dylibs). The 26 MB binary is git-ignored, built on
demand locally and in CI. (Locally the prebuilt binary may already be present; the script is
authoritative for a fresh clone / CI.)

## G2 — Project generates
```
xcodegen generate
```
Green when `PDFToolbox.xcodeproj` is (re)generated with exit 0.

## G3 — App builds
```
xcodebuild -project PDFToolbox.xcodeproj -scheme PDFToolbox -configuration Debug build
```
Green on `** BUILD SUCCEEDED **` (ad-hoc signed, hardened runtime, no Developer ID required).

## G4 — Tests pass
```
xcodebuild -project PDFToolbox.xcodeproj -scheme PDFToolbox -configuration Debug test
```
Green when every test passes. The suite includes the M1-critical test: a real Ghostscript
`pdfwrite` compression run through `GhostscriptRunner` **under `sandbox-exec`** on a synthetic
image PDF, asserting a smaller, valid, page-count-preserved output.

## G5 — DMG packages  *(Phase 2 — not yet built)*
```
scripts/package-dmg.sh
```
Green when a mountable DMG is produced (archive → deep ad-hoc sign incl. the bundled `gs` →
`hdiutil`). Added in Task S.4; until then this gate is pending, not skipped.

---

Notes:
- Fixtures are **synthetic only** (generated in-process via CoreGraphics/PDFKit). No personal
  PDFs, paths, names, or contents ever enter this repo or the test suite.
- KB (`.claude/OVERVIEW.md`, `INDEX.md`, module docs) is bootstrapped in Phase 2 (Task S.5),
  once the real modules exist, before the first branch push.
