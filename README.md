# Toolbox

A native macOS app that makes PDFs smaller and makes scans searchable — without touching your originals.

Everything runs on your Mac. Nothing is uploaded.

**Apple Silicon · macOS 14+**

## What it does

**Compress** — shrink PDFs with three quality presets. You see the predicted size and saving for each file *before* you run it.

**OCR** — make scanned PDFs searchable by adding an invisible text layer. The pages look exactly the same; you can just select and search the text.

## Install

1. Download the DMG from [Releases](../../releases).
2. Open it and drag **Toolbox** to Applications.

The app isn't notarised yet, so macOS will warn you the first time. Right-click it and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Toolbox.app
```

## How to use it

1. Pick **Compress** or **OCR** in the sidebar.
2. Drag PDFs in, or click **Choose Files**.
3. For Compress, pick a preset — *Smallest*, *Balanced* (recommended), or *High quality*.
4. Press the button.

Results are saved next to your originals as `<name>-compressed.pdf` or `<name>-ocr.pdf`, or into a folder you choose. Click any file's name to open it, or use **Reveal in Finder**.

You can queue up as many files as you like and cancel at any point.

**Your originals are never modified.** If a file can't be made smaller, it's left alone and reported as already optimised.

## Good to know

- Compression is tuned per document — text stays sharp, and black-and-white scans get special treatment that can shrink them dramatically.
- OCR skips pages that already have text.
- Colour scans compress well, but the very best results for those (MRC) aren't implemented yet.
- OCR recognises non-Latin scripts but doesn't yet embed them.

## Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/build-ghostscript.sh
xcodegen generate
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug test
scripts/package-dmg.sh         # → dist/Toolbox.dmg
```

## Licence

AGPL-3.0-or-later — see [LICENSE](LICENSE). Bundles [Ghostscript](https://www.ghostscript.com/).

Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
