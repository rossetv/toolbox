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
| Rung 3 | Spec'd but **not built**: an MRC pipeline for `.scanColour` scans. |
| Incremental update | The PDF technique `PDFWriter` uses for OCR: append new objects + a new xref + trailer with `/Prev`; original bytes are an untouched verbatim prefix. |
| Seatbelt sandbox | The `sandbox-exec` profile every Ghostscript invocation runs inside — no exception. |
| TCC-protected folder | `~/Documents`, `~/Downloads`, `~/Desktop` — folders macOS gates behind a user consent prompt that a non-interactive sandboxed child process cannot answer. |

## System boundaries

| External system | Direction | Via |
|-----------------|-----------|-----|
| Bundled Ghostscript binary | invoke (subprocess) | `Sources/Toolbox/Services/GhostscriptRunner.swift`, confined by `SeatbeltProfile.swift` |
| Apple Vision (on-device OCR) | read | `Sources/Toolbox/OCR/VisionOCR.swift` (`VNRecognizeTextRequest`) — no network |
| Local filesystem (user-selected PDFs) | read/write | `Sources/Toolbox/Compress/CompressEngine.swift`, `Sources/Toolbox/OCR/OCREngine.swift` |

No network access anywhere in the app; the seatbelt profile explicitly denies it for gs.

## Process model

1. One process. `ToolboxApp.init()` runs a headless self-test hook first
   (`TOOLBOX_SMOKE=compress` — see `App/CompressSmoke.swift`), then launches the
   SwiftUI `WindowGroup` (`RootView`).
2. Each Compress/OCR job spawns a **child process**: `/usr/bin/sandbox-exec` wrapping
   the bundled `gs` (Compress only — OCR never shells out, it calls Vision in-process).
3. `ToolQueue` runs jobs with bounded concurrency (`SystemInfo.performanceCoreCount`
   default, OCR pins 2) on the cooperative thread pool; each job body must suspend on
   its blocking work, never block a pool thread.

## Repo layout

```
Sources/Toolbox/App/           # shell: entry point, sidebar/detail split, window setup, Tool enum, smoke test
Sources/Toolbox/Compress/      # Compress tool: Rung-1/2 engine, bilevel scan/CCITT/composer, estimator, view, view model
Sources/Toolbox/OCR/           # OCR tool: engine, Vision wrapper, options, view, view model
Sources/Toolbox/Services/      # gs runner + sandbox profile, PDF inspection, output validation, PDF writer
Sources/Toolbox/Shared/        # ToolQueue (batch runner), file naming, canonical-path, system info, logging
Sources/Toolbox/Models/        # tool-agnostic value types (preset, job state/outcome, content type, estimate)
Sources/Toolbox/DesignSystem/  # Theme tokens + reusable SwiftUI components
Resources/ghostscript/            # bundled gs tree — git-ignored, built by scripts/build-ghostscript.sh
Tests/ToolboxTests/            # XCTest suite incl. a real sandboxed-gs run and synthetic fixtures
scripts/                          # build-ghostscript.sh, package-dmg.sh
.github/workflows/build.yml       # CI: build gs, xcodebuild test, package DMG, guarded notarised release
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
| Licence | AGPL-3.0-or-later | `LICENSE`, every source file's SPDX header |
