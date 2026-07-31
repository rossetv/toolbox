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
| App | Shell: entry point, single-pane window + window setup, self-update, smoke tests | `Sources/Toolbox/App/ToolboxApp.swift` | [→](modules/app.md) |
| Queue | The unified queue: one view model, every screen, progress/ETA, consent + version switch, history | `Sources/Toolbox/Queue/QueueViewModel.swift` | [→](modules/queue.md) |
| Compress | Rung-1 (Ghostscript) + Rung-2 (bilevel/CCITT) + Rung-3 (MRC) compression, estimate | `Sources/Toolbox/Compress/CompressEngine.swift` | [→](modules/compress.md) |
| OCR | Vision-based invisible text layer | `Sources/Toolbox/OCR/OCREngine.swift` | [→](modules/ocr.md) |
| Services | gs runner + sandbox, PDF inspection, output validation, PDF writer | `Sources/Toolbox/Services/GhostscriptRunner.swift` | [→](modules/services.md) |
| Shared | Batch runner, file naming, path canonicalisation, file picker, system info | `Sources/Toolbox/Shared/ToolQueue.swift` | [→](modules/shared.md) |
| Models | Tool-agnostic value types (job/preset/content-type/estimate) | `Sources/Toolbox/Models/ToolJob.swift` | [→](modules/models.md) |
| DesignSystem | Theme tokens + reusable SwiftUI components | `Sources/Toolbox/DesignSystem/Theme.swift` | [→](modules/design-system.md) |

## Key flows

1. **One pass, two legs** (`QueueViewModel.runPass`): `QueueView` (drop/pick) →
   `QueueViewModel.add` reserves the row's output name there and then (`FileNaming`, spec §6.5)
   and kicks off add-time inspection (`RowInspection`) + a time-boxed
   `CompressEstimator.analyse` → user taps Start → `QueueViewModel.compress` locks the run's
   settings (`lockedRun`) → `ToolQueue.run` runs one pass per file: the **compress leg** first
   (Rungs 2/3 rasterise pages, which would destroy a pre-existing text layer), the cancellation
   boundary, then the **OCR leg** — which recognises once from the ORIGINAL and appends the
   layer to every variant the row delivers (`runOCRLeg`, spec §6.4). Either leg can be off per
   batch or per row (`effectiveVerbs(for:)`). After the queue phase, any armed rows run serially
   through `runRecompressPhase`. See [Queue](modules/queue.md).
2. **Compress leg**: `CompressEngine.compress` → `OpenGuard.inspect`
   → stage into temp work dir → `GhostscriptRunner.run` (`sandbox-exec` + `SeatbeltProfile`) as
   the Rung-1 baseline → if `PDFService.classify` says `.scanBilevel`, also build Rung 2
   (`BilevelScan.binarise` → `CCITTEncoder.encode` → `BilevelPDFComposer.compose`, per page) and
   race it against that gs output (D7: smaller than both the gs output and the input)
   → if `.scanColour` on Balanced/Smallest, try Rung 3 (`MRCClassifier` R2/R3 → `MRCSegmenter` →
   `MRCPageEncoder` → `MRCVerifier` → `MRCComposer.compose`, per page) and weigh it against the gs
   output via the D7 document gate (smaller than both gs output and input, and validates) — a win
   ships the hybrid and parks the gs output as the runner-up (`RunnerUpStore`, `VersionStore`) for
   the popover's switch; a loss parks the validated hybrid beside the shipped gs output instead
   (R7 reversal), and an MRC failure falls through to gs → size/page-count gain check →
   `OutputValidator.validate` → atomic rename to destination.
3. **OCR leg**: `OCREngine.ocr` on the ORIGINAL → `OpenGuard.inspect` → per page:
   `PDFService.pageHasText` (skip) or render-upright + `VisionOCR.recognise` →
   `PDFWriter.appendTextLayer` (incremental update) onto each variant the row delivers →
   `OutputValidator.validate` → atomic rename. Bounded to two files at a time by the queue's own
   OCR-slot semaphore (`QueueViewModel.acquireOCRSlot`).
4. **App smoke test**: `ToolboxApp.init()` → `CompressSmoke.runIfRequested()` (only when
   `TOOLBOX_SMOKE=compress`) → synthetic in-process fixture → real `CompressEngine.compress`
   through the bundled gs under the sandbox → prints `SMOKE PASS`/`SMOKE FAIL` → exits before any
   window opens. Exercised end-to-end from the packaged DMG in CI (`.github/workflows/build.yml`).

## State & data

| State | Lives in | Written by | Read by |
|-------|----------|-----------|---------|
| Batch job list + lifecycle state | `ToolQueue.jobs` (`@Published`) | `ToolQueue` | `QueueViewModel` via a Combine `sink`, republished through `publishJobs()` |
| Per-job estimate/analysis + "analysing" overlay | `QueueViewModel.analyses`/`analysingIDs` | `QueueViewModel` | `QueueViewModel.jobs` (published, merged view) |
| Every row's versions (shipped/runner-up/previous) | `VersionStore` | `QueueViewModel` | the row copy, the versions popover, `savedSoFarBytes` |
| Bundled Ghostscript binary | `Resources/ghostscript/bin/gs` (git-ignored) | `scripts/build-ghostscript.sh` | `GhostscriptRunner.init()` via `Bundle.main` |
| Compressed/OCR'd output | `<name>-compressed.pdf` / `<name>-ocr.pdf`, alongside input or in the chosen output folder | `CompressEngine`/`OCREngine` (atomic rename) | Finder / user |

**The queue itself is never restored** — every launch starts from an empty queue, and no
row, override or reservation outlives the process. Four things *are* persisted, each for a
named reason:

| Persisted | Where | Owner |
|---|---|---|
| Recent batches + lifetime savings (spec §6.9) | `Application Support/Toolbox/history.json` (schema-versioned) | `HistoryStore` — see [Queue](modules/queue.md) |
| "Rebuild scans without asking" | `UserDefaults` (`rebuildScansWithoutAsking`) | `QueueViewModel.rebuildWithoutAsking` |
| Update-banner dismissal, per version | `UserDefaults` (`bannerDismissed`) | `UpdateBannerView` — see [App](modules/app.md) |
| The window's last frame | `UserDefaults` (frame autosave) | `WindowSetup.applyMinimumSize` — see [App](modules/app.md) |

Parked variant *files* are a fifth, deliberately transient case: `RunnerUpStore` (spec R15)
caches Rung 3's non-shipped versions under `caches/Toolbox/runner-ups`, swept once from
`QueueViewModel.init` (`RootView` owns the view model as a `@StateObject` under the app's
single `Window` scene, so this fires exactly once per run) and emptied at quit
(`AppDelegate.applicationWillTerminate`) — see [Compress](modules/compress.md),
[App](modules/app.md).

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
- **`Compress` and `OCR` are independent engines that never call each other** — but they
  are no longer independent *runs*: `QueueViewModel.runPass` sequences both legs over one
  file in one pass (compress first, then OCR), and `RowOutcome` reports them side by side.
  The engines still know nothing of each other; the queue is the only thing that composes
  them.
- **`Models` references nothing outside itself and Foundation.** These are directories in a
  single Swift module (`project.yml` declares one `Toolbox` target over `Sources/Toolbox`), so
  there are no local imports and the compiler enforces none of this — it is a review rule,
  checked by grepping a directory for the foreign type's name. Types in `Models/` must never
  name a type from `Compress`, `OCR`, `Services` or `Shared`. See `CODE_GUIDELINES.md` §2.3.
  **Two live violations stand as at 2026-07-31**, recorded here rather than quietly blessed:
  `Models/JobOutcome.swift`'s `RetainedVariant.kind` names `EngineVariant`, and
  `Models/ToolJob.swift`'s `mrcReport` names `MRCDocumentReport` — both declared under
  `Compress/` (`VersionStore.swift`, `MRC/MRCTypes.swift`).
- **`ToolQueue` is generic over its job body** — it knows nothing about PDFs,
  Ghostscript, or Vision; `QueueViewModel` supplies the closure (`runPass`). See
  [Shared](modules/shared.md).
- **Rung 2 (native bilevel scan pipeline: binarise + CCITT G4) and Rung 3 (per-page
  MRC hybrid) are both built, route on `PDFContentType`, and are both RACED against the
  Rung-1 gs output** — `.scanBilevel` builds the CCITT rebuild and ships it only when it
  beats both that gs output and the input; `.scanColour` on Balanced/Smallest tries Rung 3
  under the same D7 gate; every other case, and any failure or lost race, ships Rung 1.
