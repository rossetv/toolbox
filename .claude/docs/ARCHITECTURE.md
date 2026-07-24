<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every path, command, and constant below must
be verified against the code before writing; on contradiction, fix here at
once. Unknown fact → omit the section, never guess.
NEVER cite a line number (no `file.sh:234`, no bare `(:234)`, no ranges): any edit
above it rots the citation, and re-numbering then eats the whole maintenance budget.
Cite the file plus a stable, greppable anchor — a function, variable, constant or
check name: `scripts/kb-gate-lib.sh` (`review_key()`). Verify the anchor with grep. -->
↑ [INDEX](../INDEX.md)

# Architecture

## Module map

| Module | Responsibility | Entrypoint | Doc |
|--------|----------------|-----------|-----|
| App | Shell: entry point, sidebar/detail layout, tool enum, smoke test | `Sources/Toolbox/App/ToolboxApp.swift` | [→](modules/app.md) |
| Compress | Rung-1 (Ghostscript) + Rung-2 (bilevel/CCITT) compression, estimate, batch UI | `Sources/Toolbox/Compress/CompressEngine.swift` | [→](modules/compress.md) |
| OCR | Vision-based invisible text layer, batch UI | `Sources/Toolbox/OCR/OCREngine.swift` | [→](modules/ocr.md) |
| Services | gs runner + sandbox, PDF inspection, output validation, PDF writer | `Sources/Toolbox/Services/GhostscriptRunner.swift` | [→](modules/services.md) |
| Shared | Batch runner, file naming, path canonicalisation, system info, logging | `Sources/Toolbox/Shared/ToolQueue.swift` | [→](modules/shared.md) |
| Models | Tool-agnostic value types (job/preset/content-type/estimate) | `Sources/Toolbox/Models/ToolJob.swift` | [→](modules/models.md) |
| DesignSystem | Theme tokens + reusable SwiftUI components | `Sources/Toolbox/DesignSystem/Theme.swift` | [→](modules/design-system.md) |

## Key flows

1. **Compress**: `CompressView` (drop/pick) → `CompressViewModel.add` → `CompressEstimator.estimate`
   (per-file, time-boxed) → user taps Compress → `CompressViewModel.compress` pre-allocates
   output names (`FileNaming`) → `ToolQueue.run` → `CompressEngine.compress` → `OpenGuard.inspect`
   → stage into temp work dir → if `PDFService.classify` says `.scanBilevel`, try Rung 2 first
   (`BilevelScan.binarise` → `CCITTEncoder.encode` → `BilevelPDFComposer.compose`, per page) →
   otherwise `GhostscriptRunner.run` (`sandbox-exec` + `SeatbeltProfile`) as the Rung-1 baseline
   → if `.scanColour` on Balanced/Smallest, try Rung 3 (`MRCClassifier` R2/R3 → `MRCSegmenter` →
   `MRCPageEncoder` → `MRCVerifier` → `MRCComposer.compose`, per page) and weigh it against the gs
   output via the D7 document gate (smaller than both gs output and input, and validates) — a win
   ships the hybrid and caches the gs output as a runner-up (`RunnerUpStore`) for the popover's
   switch, a loss or any MRC failure falls through to gs → size/page-count gain check →
   `OutputValidator.validate` → atomic rename to destination.
2. **OCR**: `OCRView` (drop/pick) → `OCRViewModel.add` → user taps run → `OCRViewModel.run`
   pre-allocates output names → `ToolQueue.run` (capped at 2) → `OCREngine.ocr` → `OpenGuard.inspect`
   → per page: `PDFService.pageHasText` (skip) or render-upright + `VisionOCR.recognise` →
   `PDFWriter.appendTextLayer` (incremental update) → `OutputValidator.validate` → atomic rename.
3. **App smoke test**: `ToolboxApp.init()` → `CompressSmoke.runIfRequested()` (only when
   `TOOLBOX_SMOKE=compress`) → synthetic in-process fixture → real `CompressEngine.compress`
   through the bundled gs under the sandbox → prints `SMOKE PASS`/`SMOKE FAIL` → exits before any
   window opens. Exercised end-to-end from the packaged DMG in CI (`.github/workflows/build.yml`).

## State & data

| State | Lives in | Written by | Read by |
|-------|----------|-----------|---------|
| Batch job list + lifecycle state | `ToolQueue.jobs` (`@Published`) | `ToolQueue` | `CompressViewModel`/`OCRViewModel` via Combine `sink` |
| Per-job size estimate + "analysing" overlay | `CompressViewModel.estimates`/`.analysingIDs` | `CompressViewModel` | `CompressViewModel.jobs` (published, merged view) |
| Bundled Ghostscript binary | `Resources/ghostscript/bin/gs` (git-ignored) | `scripts/build-ghostscript.sh` | `GhostscriptRunner.init()` via `Bundle.main` |
| Compressed/OCR'd output | `<name>-compressed.pdf` / `<name>-ocr.pdf`, alongside input or in the chosen output folder | `CompressEngine`/`OCREngine` (atomic rename) | Finder / user |

No persisted app state (no UserDefaults/Core Data in scope) — every run starts from an
empty queue. The one documented exception is `RunnerUpStore` (spec R15): Rung 3's losing
gs versions live in `caches/Toolbox/runner-ups`, swept at launch and emptied at quit
(`AppDelegate.applicationWillTerminate`) — see [Compress](modules/compress.md).

## Boundaries & invariants

- **No document layer may call `Process` directly** — Ghostscript is invoked only
  through `GhostscriptRunner`, which always wraps the call in `sandbox-exec`. See
  [Services](modules/services.md) for the full sandbox contract.
- **Untrusted input never reaches a TCC-protected path inside the sandboxed child**:
  `CompressEngine` copies the input into a private temp working dir first — the
  seatbelt-sandboxed gs child cannot inherit the app's TCC grant, so it must never be
  handed a path under `~/Documents`/`~/Downloads`/`~/Desktop` directly.
  `OpenGuard.inspect` runs on the **original** input, from the parent app, which does
  hold the grant.
- **`Compress` and `OCR` are independent engines that never call each other** — a
  combined compress+OCR pass is out of scope for v1 (spec §2).
- **`Models` references nothing outside itself and Foundation.** These are directories in a
  single Swift module (`project.yml` declares one `Toolbox` target over `Sources/Toolbox`), so
  there are no local imports and the compiler enforces none of this — it is a review rule,
  checked by grepping a directory for the foreign type's name. Types in `Models/` must never
  name a type from `Compress`, `OCR`, `Services` or `Shared`. See `CODE_GUIDELINES.md` §2.3.
- **`ToolQueue` is generic over its job body** — it knows nothing about PDFs,
  Ghostscript, or Vision; both view models supply the tool-specific closure. See
  [Shared](modules/shared.md).
- **Rung 2 (native bilevel scan pipeline: binarise + CCITT G4) and Rung 3 (per-page
  MRC hybrid) are both built and route on `PDFContentType`** — `.scanBilevel` tries
  Rung 2 first, falling back to Rung-1 Ghostscript on any failure or no gain;
  `.scanColour` on Balanced/Smallest tries Rung 3, weighed against the Rung-1 gs
  output via the D7 gate; every other case (or Rung-3 loss/failure) goes to Rung 1.
