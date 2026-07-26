<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every path, command, and constant below must
be verified against the code before writing; on contradiction, fix here at
once. Unknown fact → omit the section, never guess.
NEVER cite a line number (no `file.sh:234`, no bare `(:234)`, no ranges): any edit
above it rots the citation, and re-numbering then eats the whole maintenance budget.
Cite the file plus a stable, greppable anchor — a function, variable, constant or
check name: `scripts/kb-gate-lib.sh` (`review_key()`). Verify the anchor with grep. -->
↑ [INDEX](INDEX.md)

# Toolbox — Overview

## What & why

Native macOS app (SwiftUI, macOS 14+, Apple Silicon) that compresses and OCRs PDFs
locally — no cloud upload, no subscription. An extensible sidebar shell; v1 ships two
tools, **Compress** and **OCR**, sharing a queue/batch/state machine. Named "toolbox"
because more PDF utilities are planned — the sidebar lists only tools that are
actually built (`Tool`), not placeholders for ones that aren't.

## Domain concepts

| Term | Meaning |
|------|---------|
| Rung 1 | Tuned Ghostscript `pdfwrite` — the fallback path for every document, and the only path for any classification other than `.scanBilevel`. |
| Rung 2 | Built: binarise a visually two-tone (`.scanBilevel`) scan, then encode CCITT G4 via ImageIO — tried first for that content type, falling back to Rung 1 on any failure or no gain. |
| Rung 3 | Built: per-page MRC (classify + Sauvola-class segment + CCITT mask/JPEG fg-bg layers + verify + compose) for `.scanColour` scans on Balanced/Smallest, weighed against the Rung-1 gs output via the D7 document gate; a losing gs version is retained as a runner-up the user can switch to. |
| Incremental update | The PDF technique `PDFWriter` uses for OCR: append new objects + a new xref + trailer with `/Prev`; original bytes are an untouched verbatim prefix. |
| Seatbelt sandbox | The `sandbox-exec` profile every Ghostscript invocation runs inside — no exception. |
| TCC-protected folder | `~/Documents`, `~/Downloads`, `~/Desktop` — folders macOS gates behind a user consent prompt that a non-interactive sandboxed child process cannot answer. |

## System boundaries

| External system | Direction | Via |
|-----------------|-----------|-----|
| Bundled Ghostscript binary | invoke (subprocess) | `Sources/Toolbox/Services/GhostscriptRunner.swift`, confined by `SeatbeltProfile.swift` |
| Apple Vision (on-device OCR) | read | `Sources/Toolbox/OCR/VisionOCR.swift` (`VNRecognizeTextRequest`) — no network |
| Local filesystem (user-selected PDFs) | read/write | `Sources/Toolbox/Compress/CompressEngine.swift`, `Sources/Toolbox/OCR/OCREngine.swift` |
| GitHub Releases API (`api.github.com`) | read (on launch) | `Sources/Toolbox/App/UpdateChecker.swift` — notify-only version check; never downloads or self-replaces |

The seatbelt profile explicitly denies gs network access, and no PDF content ever leaves
the Mac; the single exception is `UpdateChecker`'s on-launch GET to GitHub Releases (the
app's only network request), which sends nothing about the user or their files.

## Process model

1. One process. `ToolboxApp.init()` runs a headless self-test hook first
   (`TOOLBOX_SMOKE=compress` — see `App/CompressSmoke.swift`), then a single-instance
   guard (`yieldToExistingInstance()` — activates and yields to an already-running copy
   of the bundle, skipped under XCTest), then launches a single SwiftUI `Window` scene
   (`ToolboxApp.body`, id `"main"` — not `WindowGroup`: a group hands out File ▸ New
   Window, and the tool view models are not built to be duplicated) hosting `RootView`,
   which kicks off `UpdateChecker.check()` in a `.task`. `RootView` owns the
   `CompressViewModel`/`OCRViewModel` as `@StateObject`s, so each is constructed exactly
   once per app run.
2. Each Compress/OCR job spawns a **child process**: `/usr/bin/sandbox-exec` wrapping
   the bundled `gs` (Compress only — OCR never shells out, it calls Vision in-process).
3. `ToolQueue` runs jobs with bounded concurrency (`SystemInfo.performanceCoreCount`
   default, OCR pins 2) on the cooperative thread pool; each job body must suspend on
   its blocking work, never block a pool thread.

## Repo layout

```
Sources/Toolbox/App/           # shell: entry point, sidebar/detail split, window setup, Tool enum, smoke test
Sources/Toolbox/Compress/      # Compress tool: Rung-1/2/3 engine, bilevel scan/CCITT/composer, MRC/ pipeline, runner-up store, estimator, view, view model
Sources/Toolbox/OCR/           # OCR tool: engine, Vision wrapper, options, view, view model
Sources/Toolbox/Services/      # gs runner + sandbox profile, PDF inspection, output validation, PDF writer
Sources/Toolbox/Shared/        # ToolQueue (batch runner), file naming, canonical-path, system info, logging
Sources/Toolbox/Models/        # tool-agnostic value types (preset, job state/outcome, content type, estimate)
Sources/Toolbox/DesignSystem/  # Theme tokens + reusable SwiftUI components
Resources/ghostscript/            # bundled gs tree — git-ignored, built by scripts/build-ghostscript.sh
Tests/ToolboxTests/            # XCTest suite incl. a real sandboxed-gs run and synthetic fixtures
scripts/                          # build-ghostscript.sh, package-dmg.sh, install.sh (user-facing one-line installer), make-app-icon.sh/.swift
.github/workflows/build.yml       # CI: select Xcode 26 (Icon Composer .icon needs actool 26; older toolchains
                                  # build an icon-less bundle without erroring), build gs, xcodebuild test,
                                  # package DMG (tag builds pass VERSION=<tag> through), guarded notarised release
```

## Key constants

| Constant | Default | Source |
|----------|---------|--------|
| Ghostscript version | 10.07.1 | `scripts/build-ghostscript.sh` (`GS_VERSION`) |
| gs wall-clock timeout | 300 s | `Services/GhostscriptRunner.swift` (`wallClockTimeout` default) |
| macOS deployment target | 14.0 | `project.yml` (`MACOSX_DEPLOYMENT_TARGET`) |
| OCR render resolution | 300 DPI | `OCR/OCREngine.swift` (`renderDPI`) |
| Compress estimate time-box | 0.5 s | `Compress/CompressEstimator.swift` (`timeBudget` default) |
| Output-validation sample pages | 3 | `Services/OutputValidator.swift` (`validate(samplePages:)` default) |
| App bundle ID | `com.toolbox.app` | `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`) |
| App version | `0.1.0`, or the pushed tag on a tag build | `project.yml` (`MARKETING_VERSION`), overridden by `scripts/package-dmg.sh` (`VERSION` env, wired from `GITHUB_REF_NAME` in `.github/workflows/build.yml` for tag builds) |
| Licence | AGPL-3.0-or-later | `LICENSE`, every source file's SPDX header |
