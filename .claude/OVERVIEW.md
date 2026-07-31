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
locally — no cloud upload, no subscription. One window, one queue: **Compress** and
**OCR** are two *verbs* of a single pass over the queued files (spec §6.2), not two
separately-selected tools, so a file can come back both smaller and searchable.
Named "toolbox" because more PDF utilities are planned.

## Domain concepts

| Term | Meaning |
|------|---------|
| Rung 1 | Tuned Ghostscript `pdfwrite` — the baseline every document runs, the only path for anything Rungs 2/3 do not claim, and the fallback whenever a rung fails or loses its race. |
| Rung 2 | Built: binarise a visually two-tone (`.scanBilevel`) scan, then encode CCITT G4 via ImageIO — gs still runs and the rebuild is *raced* against it (the same D7 gate Rung 3 uses), shipping only when smaller than both the gs output and the input. |
| Rung 3 | Built: per-page MRC (classify + Sauvola-class segment + CCITT mask/JPEG fg-bg layers + verify + compose) for `.scanColour` scans on Balanced/Smallest, weighed against the Rung-1 gs output via the D7 document gate; whichever side loses is retained as the runner-up (spec §5's R7 reversal — the choice is about the look of the page, not only bytes) and the user can switch to it. |
| Incremental update | The PDF technique `PDFWriter` uses for OCR: append new objects + a new xref + trailer with `/Prev`; original bytes are an untouched verbatim prefix. |
| Seatbelt sandbox | The `sandbox-exec` profile every Ghostscript invocation runs inside — no exception. |
| TCC-protected folder | `~/Documents`, `~/Downloads`, `~/Desktop` — folders macOS gates behind a user consent prompt that a non-interactive sandboxed child process cannot answer. |

## System boundaries

| External system | Direction | Via |
|-----------------|-----------|-----|
| Bundled Ghostscript binary | invoke (subprocess) | `Sources/Toolbox/Services/GhostscriptRunner.swift`, confined by `SeatbeltProfile.swift` |
| Apple Vision (on-device OCR) | read | `Sources/Toolbox/OCR/VisionOCR.swift` (`VNRecognizeTextRequest`) — no network |
| Local filesystem (user-selected PDFs) | read/write | `Sources/Toolbox/Compress/CompressEngine.swift`, `Sources/Toolbox/OCR/OCREngine.swift` |
| GitHub Releases API (`api.github.com`) + release DMG download | read (on launch) + user-initiated download/self-replace | `Sources/Toolbox/App/UpdateChecker.swift` (on-launch version check, notify-only) / `Sources/Toolbox/App/SelfUpdater.swift` (user-clicked "Update" button: downloads + checksum-verifies the release DMG, then self-replaces the running bundle — mirrors `scripts/install.sh`) |

The seatbelt profile explicitly denies gs network access, and no PDF content ever leaves
the Mac; the only UNPROMPTED network request is `UpdateChecker`'s on-launch GET to GitHub
Releases, which sends nothing about the user or their files. Clicking the update banner's
button is a separate, user-initiated action: `SelfUpdater` downloads the release DMG + its
published checksum from GitHub, verifies it, and swaps the running app for it — the DMG is
self-signed (no code-signature verification is possible), so HTTPS to GitHub is the whole
trust anchor (posture reversal recorded in `DECISIONS.md`).

## Process model

1. One process. `ToolboxApp.init()` runs a headless self-test hook first
   (`TOOLBOX_SMOKE=compress` — see `App/CompressSmoke.swift`), then a single-instance
   guard (`yieldToExistingInstance()` — activates and yields to an already-running copy
   of the bundle, skipped under XCTest), then launches a single SwiftUI `Window` scene
   (`ToolboxApp.body`, id `"main"` — not `WindowGroup`: a group hands out File ▸ New
   Window, and the view model is not built to be duplicated) hosting `RootView`,
   which kicks off `UpdateChecker.check()` in a `.task`. `RootView` owns the single
   `QueueViewModel` (and `SelfUpdater`/`UpdateChecker`) as `@StateObject`s, so each is
   constructed exactly once per app run.
2. A file's compress leg spawns a **child process**: `/usr/bin/sandbox-exec` wrapping
   the bundled `gs`. The OCR leg never shells out — it calls Vision in-process.
3. `ToolQueue` runs one pass per file with bounded concurrency
   (`SystemInfo.performanceCoreCount` by default) on the cooperative thread pool; each
   job body must suspend on its blocking work, never block a pool thread. The OCR leg
   holds its own two-slot semaphore inside the run (`QueueViewModel.ocrConcurrency`,
   `acquireOCRSlot`), so Vision never sees the full batch width.

## Repo layout

```
Sources/Toolbox/App/           # shell: entry point, single-pane RootView, window setup, self-update, smoke tests
Sources/Toolbox/Queue/         # the unified queue: view model, every screen, popovers/sheets, batch progress, history store
Sources/Toolbox/Compress/      # compress leg: Rung-1/2/3 engine, bilevel scan/CCITT/composer, MRC/ pipeline, version + runner-up stores, estimator
Sources/Toolbox/OCR/           # OCR leg: engine, Vision wrapper, options
Sources/Toolbox/Services/      # gs runner + sandbox profile, PDF inspection, output validation, PDF writer
Sources/Toolbox/Shared/        # ToolQueue (batch runner), file naming, canonical-path, file picker, blocking offload, system info
Sources/Toolbox/Models/        # leg-agnostic value types (preset, job state/outcome, content type, estimate)
Sources/Toolbox/DesignSystem/  # Theme tokens + reusable SwiftUI components
Resources/ghostscript/            # bundled gs tree — git-ignored, built by scripts/build-ghostscript.sh
Tests/ToolboxTests/            # XCTest suite incl. a real sandboxed-gs run and synthetic fixtures
scripts/                          # build-ghostscript.sh, package-dmg.sh, install.sh (user-facing one-line installer), make-app-icon.sh/.swift
.github/workflows/build.yml       # CI: select Xcode 26 (Icon Composer .icon needs actool 26; older toolchains
                                  # build an icon-less bundle without erroring), build gs, xcodebuild test,
                                  # package DMG (tag builds pass VERSION=<tag less its v> through), guarded notarised release
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
| App version | `0.1.0`, or the pushed tag less its leading `v` on a tag build; every CI build stamps the build number from the run number | `project.yml` (`MARKETING_VERSION`), overridden by `scripts/package-dmg.sh` (`VERSION` env, wired from `GITHUB_REF_NAME` in `.github/workflows/build.yml` for tag builds) |
| Licence | AGPL-3.0-or-later | `LICENSE`, every source file's SPDX header |
