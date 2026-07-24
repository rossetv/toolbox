<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every path, command, and constant below must
be verified against the code before writing; on contradiction, fix here at
once. Unknown fact → omit the section, never guess.
NEVER cite a line number (no `file.sh:234`, no bare `(:234)`, no ranges): any edit
above it rots the citation, and re-numbering then eats the whole maintenance budget.
Cite the file plus a stable, greppable anchor — a function, variable, constant or
check name: `scripts/kb-gate-lib.sh` (`review_key()`). Verify the anchor with grep. -->
↑ [INDEX](../../INDEX.md)

# Module: Compress

## Purpose

The Compress tool: Rung 1 (tuned Ghostscript `pdfwrite`) for every document, with Rung 2
(binarise + CCITT G4 via ImageIO) tried first for scans that classify as visually
two-tone, falling back to Rung 1 on any failure or no gain; and Rung 3 (per-page MRC
hybrid) tried for `.scanColour` documents on Balanced/Smallest, weighed against the
Rung-1 gs output via the D7 document gate. Also estimates the output size before
running and drives the batch UI.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/Compress/CompressEngine.swift` | `CompressEngine.compress(_:preset:to:progress:)` — stage/run/validate/atomically-place one file; routes `.scanBilevel` documents through Rung 2 first (`bilevelCompress`) |
| `Sources/Toolbox/Compress/BilevelScan.swift` | `BilevelScan.binarise(_:)` — near-bilevel gate (`isNearBilevel`) + Otsu-threshold reduction to 1-bit `/DeviceGray` |
| `Sources/Toolbox/Compress/CCITTEncoder.swift` | `CCITTEncoder.encode(_:)` — CCITT Group 4 via an in-memory TIFF (ImageIO), strip lifted back out for `/CCITTFaxDecode` |
| `Sources/Toolbox/Compress/BilevelPDFComposer.swift` | `BilevelPDFComposer.compose(pages:)` — builds a fresh classic-xref PDF whose pages are CCITT image XObjects |
| `Sources/Toolbox/Compress/CompressEstimator.swift` | `CompressEstimator.estimate(_:preset:)` — time-boxed, parse-only pre-run size prediction |
| `Sources/Toolbox/Compress/CompressViewModel.swift` | `@MainActor` state: queue, preset, output folder, per-job estimate overlay, heavy-version switch (`heavyVersions(for:)`, `switchVersion(for:)`, `rerunForSwitch`) |
| `Sources/Toolbox/Compress/CompressView.swift` | Drop zone, file rows, preset picker, output-folder row, run/cancel |
| `Sources/Toolbox/Compress/HeavyCompressionPopover.swift` | The heavy-capsule popover: shows both versions, drives `switchVersion(for:)` |
| `Sources/Toolbox/Compress/RunnerUpStore.swift` | `RunnerUpStore` — `@MainActor` cache of losing (gs) versions for `.compressedHeavy` jobs (spec R15, documented exception to "no persisted app state"); `sweepStale()` on launch, `removeAllOnDisk()` on quit (`AppDelegate.applicationWillTerminate`, see [App](app.md)) |
| `Sources/Toolbox/Compress/MRC/MRCClassifier.swift` | `MRCClassifier.structure(of:)` (R2 structural sweep), `.features(of:)` + `.verdict(features:)` (R3 eligibility envelope) |
| `Sources/Toolbox/Compress/MRC/MRCSegmenter.swift` | `MRCSegmenter.binarise(_:)` (Sauvola-class local-threshold text mask) + `.segment(_:)` (fg/bg colour-layer split, block-granular fill of the other class) |
| `Sources/Toolbox/Compress/MRC/MRCPageEncoder.swift` | `MRCPageEncoder.encode(_:preset:)` — CCITT mask + JPEG fg/bg layers; `.recompose(_:)` rebuilds a page for the verifier |
| `Sources/Toolbox/Compress/MRC/MRCVerifier.swift` | `MRCVerifier.score(candidate:input:mask:)` — ink-weighted relative-error post-encode gate |
| `Sources/Toolbox/Compress/MRC/MRCComposer.swift` | `MRCComposer.compose(pages:)` — classic-xref PDF, mask + fg/bg JPEG XObjects per page |
| `Sources/Toolbox/Compress/MRC/MRCTypes.swift` | `MRCPageFeatures`, `MRCDeclineReason`, `MRCPageVerdict`, `MRCDocumentReport` — spec §6's per-page debugging record |

## Invariants

- **Routing is content-based, whole-document, and fails safe to Rung 1**
  (`CompressEngine.compress`): only when `PDFService.classify` returns `.scanBilevel`
  is Rung 2 attempted at all; any page failing the bilevel gate aborts the *whole*
  attempt (`bilevelCompress` returns nil) and gs runs instead — a single wrongly
  binarised page is a worse outcome than a missed saving. A Rung-2 result must also be
  smaller than the input and pass `OutputValidator` before it is used; otherwise Rung 1
  runs. Per-page (rather than whole-document) routing is not built (spec §5.1, v1.1).
- **Rung 2's near-bilevel gate is deliberately strict** (`BilevelScan`): almost every
  sampled pixel must be near-black or near-white (`extremeFraction`) *and* almost none
  may carry real chroma (`chromaFraction`) — luminance alone would let a saturated
  colour on white sail through. `otsuThreshold` (mid-point of the maximal-variance
  plateau, not the first) picks the black/white cut rather than a fixed 50%.
- **`CCITTEncoder` uses no native/bespoke codec** — it asks ImageIO for a TIFF with
  `Compression = 4` and parses just enough of the baseline TIFF structure back out to
  lift the compressed strip; PDF's `/CCITTFaxDecode` with `/K -1` consumes that
  bitstream directly.
- **`BilevelPDFComposer` writes a brand-new classic-xref PDF, not an edit of the
  original** — Rung 2 replaces the page's content entirely, so there is nothing to
  preserve incrementally (unlike OCR's `PDFWriter`, see [Services](services.md)). Page
  geometry is emitted as PDF reals (not rounded) so the image is never stretched to a
  rounded box.
- **Bilevel rendering is DPI- and dimension-bounded** (`CompressEngine.bilevelCompress`
  scales by `CompressPreset.bilevelDPI` but caps the longest side at 5000px) so a
  hostile `/MediaBox` cannot blow memory.
- **Never emits a larger file**: `CompressEngine.compress` compares output vs input
  bytes; if not smaller, returns `.noGain` and writes nothing to the destination — but
  first re-opens the gs output and checks its page count, so a same-size *corruption*
  never masquerades as "already optimised".
- **gs I/O is staged through a private temp working dir**, never the input's real
  location: a seatbelt-sandboxed gs child cannot inherit the app's TCC grant, so
  handing it a path under `~/Documents`/`~/Downloads`/`~/Desktop` directly would hang
  on an unanswerable TCC prompt. The parent app (which holds the grant) copies the
  input in and the result back out.
- **Atomic placement**: the result is copied onto the destination volume under a
  hidden UUID name, then `moveItem` (same-volume rename) into the final path — a
  cancelled or failed job leaves no partial output at the destination.
- **A gs exit 0 with zero-byte output is a hard failure**, never treated as
  "already optimised" (`CompressEngine.compress`, step 4).
- Output names for a whole batch are **pre-allocated serially, before the concurrent
  run starts** (`CompressViewModel.compress` — see `FileNaming.output(for:suffix:folder:reserving:)`
  in [Shared](shared.md)): a purely on-disk existence check races when two queued
  inputs share a basename, so allocation must happen on one thread first.
- **Rung 3 routes on `wantsMRC`** (`CompressEngine.compress`): a `.scanColour`
  document at any preset except `.maximumQuality` runs the gs pass first (unchanged —
  it is the D7 baseline), then attempts `mrcCompress`. Any MRC failure other than
  `CancellationError` declines to the gs output (D10) — the document is never worse
  off than before Rung 3 existed. The R2 structural sweep (`MRCClassifier.structure`)
  runs over every page before any rendering: one non-`.simpleSingleImage` page kills
  the whole attempt, because the fallback path rasterises and rasterising real text is
  destructive.
- **D7 document gate**: the hybrid ships only when it is smaller than *both* the gs
  output and the input, and passes `OutputValidator`. If it wins but the gs output
  itself was not smaller than the input, the hybrid ships as a plain `.compressed`
  result with no runner-up (R7 — nothing legitimate to switch to). Otherwise it ships
  `.compressedHeavy(before:after:runnerUpBytes:)` and the gs output is copied to
  `alternateOutput`, becoming the runner-up.
- **`RunnerUpStore` is the one documented exception to "no persisted app state"**
  (spec R15): it caches the losing gs version on disk (`caches/Toolbox/runner-ups`) so
  the heavy-capsule popover's switch is instant. `sweepStale()` runs at launch,
  `removeAllOnDisk()` at quit (`AppDelegate.applicationWillTerminate`) — a crash
  between the two just leaves stale cache files, cleaned on the next launch.
  `switchVersions(shipped:runnerUp:)` exchanges file *content* via three moves (park →
  promote → demote), never rewriting either path, so a mid-switch crash restores the
  shipped file rather than losing it. If the cached runner-up has vanished by the time
  the user switches, `CompressViewModel.rerunForSwitch` honestly re-runs the job (R10)
  rather than failing silently.
- **Calibrated MRC constants** (M2 corpus-tuned, 2026-07-24): `MRCSegmenter.bgDownsample`
  = 3, `.fgDownsample` = 6 (foreground ink colour is downsampled coarser than the
  paper/illustration background — the 1-bit mask already carries ink's sharp edges, so
  the fg colour layer can afford to be blockier; both then compress cheaply as JPEG
  because each has had the other class's hard edges smoothed away); `MRCVerifier.maxNormalisedError`
  = 0.33 (ink-weighted relative-error pass/fail threshold); `CompressEngine.maxMRCPages`
  = 400 (≈ `maxBilevelPages` / 3 — MRC holds three encoded layers per page and
  recomposes each to verify it, so its per-page peak is several times Rung 2's).
- **Recorded verifier limitation**: the ink-weighted relative verifier (R4) cannot
  separate image-dominant harm from a good page — that damage lives off the ink mask.
  The classifier envelope (R3) measurably excludes every harmful corpus page instead
  (including all photo-class pages); the switch UI is the human backstop. See
  `.claude/DECISIONS.md`, 2026-07-24, for the measured detail.

## Gotchas

- `CompressPreset.gsArguments()` figures (DPI, `/ebook` etc.) are a **concrete
  provisional baseline**, not corpus-tuned — expect them to change without an
  architecture change.
- `CompressEstimator`'s reduction percentages are heuristic (byte-density-per-page
  proxy for image payload), not measured against a real corpus; `isFallback` flags
  when the time-box (0.5 s) was exceeded or analysis failed, falling back to a flat
  per-preset typical range.

## Extension points

- Per-page (rather than whole-document) Rung 2 routing is spec'd for v1.1, not v1.

## Related

- Modules: [Services](services.md), [Shared](shared.md), [Models](models.md), [App](app.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §5, `.claude/specs/20260723-mrc-rung3.md`
