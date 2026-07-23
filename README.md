# PDF Toolbox

A native macOS app that makes PDFs smaller and makes scans searchable — without touching your originals. Fully offline; nothing is uploaded.

**SwiftUI · Apple Silicon · macOS 14+ · AGPL-3.0**

- **Compress** — three quality presets, with a size prediction before you commit.
- **OCR** — adds an invisible searchable text layer to scans, leaving every page image byte-for-byte identical.

Drop files in, pick a preset, go. Batch queue, cancellable, results saved alongside the originals.

## Install

Download the DMG from [Releases](../../releases) and drag **PDF Toolbox** to Applications.

Builds are ad-hoc signed and **not notarised**, so Gatekeeper will object to a downloaded copy — right-click → **Open**, or:

```sh
xattr -dr com.apple.quarantine /Applications/PDFToolbox.app
```

## How it works

Compression routes by content. **Ghostscript** (bundled, built from source) handles born-digital and mixed documents. Pages that are visually two-tone are instead **binarised and CCITT G4 encoded** — Ghostscript's mono settings only apply to images that are *already* 1-bit, so a greyscale scan that merely looks black-and-white gets treated as a grey image and can come out larger. Binarising first is where the large saving on document scans lives.

That path is conservative: every page must independently read as near-two-tone or the attempt is abandoned, because binarising a photo destroys it. Anything that fails, or fails to get smaller, falls back to Ghostscript.

**OCR** uses Apple's Vision framework on-device and embeds text by PDF *incremental update* — the original file is the verbatim byte prefix of the output, which is what makes "your images are untouched" literally true.

**Ghostscript runs sandboxed.** PDFs are untrusted input, so every invocation is confined by a `sandbox-exec` profile: deny-by-default, no network, filesystem scoped to a private temp directory, plus `-dSAFER` and a watchdog.

### Safety rules

Enforced in code and covered by tests:

- Originals are never modified; output is written to a temp file and moved into place atomically.
- No output is ever larger than its input — if compression can't win, nothing is written.
- Every output is re-opened and validated before it's accepted.
- OCR output is rejected unless the original is its verbatim byte prefix and every page that received text still renders and yields text. A writer bug becomes "file skipped", never a corrupted document.

## Limitations

- Not notarised (see Install) — needs an Apple Developer ID.
- **MRC not implemented** — where the big wins on *colour* scans would come from. Needs a segmentation-quality spike first; omitting it is deliberate.
- **JBIG2 not implemented** — better than CCITT on bilevel scans, but needs viewer-support verification. CCITT is universal.
- Non-Latin OCR (CJK, Arabic) is recognised but not embedded.
- Apple Silicon only.

## Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/build-ghostscript.sh   # pins + verifies the release, then builds (~5-10 min)
xcodegen generate
xcodebuild -project PDFToolbox.xcodeproj -scheme PDFToolbox -configuration Debug test
scripts/package-dmg.sh         # → dist/PDFToolbox.dmg
```

Ghostscript is built from source, not vendored, and links only system libraries — no Homebrew dependency at runtime. Built artefacts are git-ignored; the repository contains no binaries.

## Licence

**AGPL-3.0-or-later** ([LICENSE](LICENSE)). Not a preference — bundling [Ghostscript](https://www.ghostscript.com/) (AGPL) obliges the whole app to be AGPL. Consequence: the Mac App Store is permanently unavailable, so distribution is by DMG.

Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
