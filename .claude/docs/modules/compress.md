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

The Compress tool: Rung 1 (tuned Ghostscript `pdfwrite`) for every document; Rung 2
(binarise + CCITT G4 via ImageIO) for scans that classify as visually two-tone, **raced
against the gs output** (D7, like Rung 3) and shipped only when smaller; and Rung 3
(per-page MRC hybrid) for `.scanColour` documents on Balanced/Smallest, weighed against
the Rung-1 gs output via the same gate. Also estimates the output size before running
and drives the batch UI.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/Compress/CompressEngine.swift` | `CompressEngine.compress(_:preset:to:progress:)` — stage/run/validate/atomically-place one file; runs gs then **races** Rung 2 (`bilevelCompress`) against it for `.scanBilevel` documents |
| `Sources/Toolbox/Compress/BilevelScan.swift` | `BilevelScan.binarise(_:)` — near-bilevel gate (`isNearBilevel`) + Otsu-threshold reduction to 1-bit `/DeviceGray` |
| `Sources/Toolbox/Compress/CCITTEncoder.swift` | `CCITTEncoder.encode(_:)` — CCITT Group 4 via an in-memory TIFF (ImageIO), strip lifted back out for `/CCITTFaxDecode` |
| `Sources/Toolbox/Compress/BilevelPDFComposer.swift` | `BilevelPDFComposer.compose(pages:)` — builds a fresh classic-xref PDF whose pages are CCITT image XObjects |
| `Sources/Toolbox/Compress/CompressEstimator.swift` | `CompressEstimator.estimate(_:preset:)` (single preset) and `.analyse(_:mrcEligible:)` (every preset from one analysis pass, feeds `recompressPrediction`) — time-boxed, parse-only pre-run size prediction |
| `Sources/Toolbox/Queue/QueueViewModel.swift` | `@MainActor` state for the **whole queue** — Compress and OCR share one view model and one job list, one instance per `RootView` (see [App](app.md)); this doc covers only its Compress-specific surface (OCR's is in [OCR](ocr.md)): the recompress/arm flow (`recompressState(for:)`, `armedJobs`, `recompressPrediction(for:at:)`, `runRecompressPhase`) and the version switch (`versions(for:)`, `useVersion(_:for:)`) — both drive `VersionStore`. Formerly `Compress/CompressViewModel.swift`, folded in when Compress and OCR became one queue |
| `Sources/Toolbox/Queue/QueueView.swift`, `QueueRowsView.swift`, `QueueHeaderView.swift`, `QueueFooterView.swift` | Drop zone, file rows, preset picker, output-folder row, run/cancel — the unified queue UI that replaced `Compress/CompressView.swift` |
| `Sources/Toolbox/Compress/VersionStore.swift` | `VersionStore` — `@MainActor` display authority for every row's versions (R14); `RowVersions` (shipped/runnerUp/previous + `cards`, `capsuleTitle`), `FileVersion`, `EngineVariant` (`.mrc`/`.plain`/`.original`); the only path that discards a parked file (`setSlot`, `discardRow`, `retain(only:)`) |
| `Sources/Toolbox/Queue/VersionsPopoverContent.swift` | The capsule's popover: every version of a row (shipped/runner-up/previous) as thumbnail cards, "Use this" drives `QueueViewModel.useVersion(_:for:)` — replaced the deleted `Compress/VersionsPopover.swift` |
| `Sources/Toolbox/Compress/RunnerUpStore.swift` | `RunnerUpStore` — `@MainActor` cache of parked (runner-up and previous) versions on disk (spec R15, documented exception to "no persisted app state"); `sweepStale()` runs once from `QueueViewModel.init` (see [App](app.md) — `RootView` owns the view model as a `@StateObject` under the app's single `Window` scene, so this fires exactly once per run), `removeAllOnDisk()` on quit (`AppDelegate.applicationWillTerminate`, see [App](app.md)) |
| `Sources/Toolbox/Compress/MRC/MRCClassifier.swift` | `MRCClassifier.structure(of:)` (R2 structural sweep), `.features(of:)` + `.verdict(features:)` (R3 eligibility envelope), `.sourceImageLongEdge(of:)` (the scan's native pixel resolution — caps the MRC render DPI) |
| `Sources/Toolbox/Compress/MRC/MRCSegmenter.swift` | `MRCSegmenter.binarise(_:)` (Sauvola-class local-threshold text mask) + `.segment(_:)` (fg/bg colour-layer split; `colourLayer(…flatFill:)` fills the other class — spread-fill for the paper background, flat global-mean fill for the ink foreground) |
| `Sources/Toolbox/Compress/MRC/MRCPageEncoder.swift` | `MRCPageEncoder.encode(_:preset:)` — CCITT mask + JPEG fg/bg layers; **re-emits the foreground at `MRCSegmenter.foregroundLayerScale` of the mask resolution** (`resample`) so the mask soft-mask stays sharp; `.recompose(_:)` rebuilds a page for the verifier |
| `Sources/Toolbox/Compress/MRC/MRCVerifier.swift` | `MRCVerifier.score(candidate:input:mask:)` — ink-weighted relative-error post-encode gate |
| `Sources/Toolbox/Compress/MRC/MRCComposer.swift` | `MRCComposer.compose(pages:)` — classic-xref PDF, mask + fg/bg JPEG XObjects per page |
| `Sources/Toolbox/Compress/MRC/MRCTypes.swift` | `MRCPageFeatures`, `MRCDeclineReason`, `MRCPageVerdict`, `MRCDocumentReport` — spec §6's per-page debugging record |

## Invariants

- **Routing is content-based, whole-document, and fails safe to Rung 1**
  (`CompressEngine.compress`): only when `PDFService.classify` returns `.scanBilevel`
  is Rung 2 attempted at all; any page failing the bilevel gate aborts the *whole*
  attempt (`bilevelCompress` returns nil) and gs ships instead — a single wrongly
  binarised page is a worse outcome than a missed saving. Per-page (rather than
  whole-document) routing is not built (spec §5.1, v1.1).
- **`classify` distinguishes a scan from a born-digital document by image-XObject
  coverage, not text length alone** (`PDFService.classify` +
  `MRCClassifier.imageXObjectCoverage`): a page whose images cover ≥ `minScanCoverage`
  of it at `scanReferenceDPI` is a scan **even when it carries a text layer**. Without
  this, an image scan that had been OCR'd (this app's own OCR adds text on every page)
  was miscounted as born-digital and routed away from Rung 2 to the far weaker gs
  result. A genuine born-digital page that merely embeds a logo/QR reads a small
  fraction and stays `.bornDigital` (measured corpus separation: true scans ≥ 4.0,
  born-digital ≤ 0.14; the 0.5 threshold clears both by ~3.5×).
- **The Rung-2 rebuild is raced against the gs candidate, not merely the input**
  (`CompressEngine.compress`, step 4b): gs always runs for a `.scanBilevel` document and
  the CCITT rebuild ships only when it is smaller than **both** the gs output and the
  input and passes `OutputValidator` — mirroring the Rung-3 D7 gate. This is what makes
  opening Rung 2 to noisy or OCR'd scans safe: on a document where gs's mono downsampling
  wins (binarising scanner speckle can *inflate* CCITT), Rung 2 simply loses the race and
  gs ships, so a routing change can never regress a document.
- **Rung 2's near-bilevel gate is deliberately strict** (`BilevelScan`): almost every
  sampled pixel must be near-black or near-white (`extremeFraction`) *and* almost none
  may carry real chroma above `chromaCeiling` (`chromaFraction`) — luminance alone
  would let a saturated colour on white sail through. `chromaCeiling`/`chromaFraction`
  were tightened 2026-07-27 (40→25, 0.02→0.005) after the looser gate binarised small
  colour elements — stamps, signatures — occupying ~1% of a page; see
  `.claude/DECISIONS.md`, 2026-07-27 entry, for the measured basis. `otsuThreshold`
  (mid-point of the maximal-variance plateau, not the first) picks the black/white cut
  rather than a fixed 50%.
- **`CCITTEncoder` uses no native/bespoke codec** — it asks ImageIO for a TIFF with
  `Compression = 4` and parses just enough of the baseline TIFF structure back out to
  lift the compressed strip; PDF's `/CCITTFaxDecode` with `/K -1` consumes that
  bitstream directly.
- **`BilevelPDFComposer` writes a brand-new classic-xref PDF, not an edit of the
  original** — Rung 2 replaces the page's content entirely, so there is nothing to
  preserve incrementally (unlike OCR's `PDFWriter`, see [Services](services.md)). Page
  geometry is emitted as PDF reals (not rounded) so the image is never stretched to a
  rounded box.
- **A scan's OCR text layer survives the Rung-2 rebuild** (`BilevelPDFComposer.Page.text`
  + `CompressEngine.extractTextLayer`): before binarising, `bilevelCompress` extracts each
  page's line runs (`PDFSelection.selectionsByLine`), normalises them to the composed
  page's displayed space, and the composer re-emits them as an invisible layer through the
  **same** `PDFWriter.contentStream` the OCR tool uses (shared Helvetica font). A text page
  declines the whole document to gs — which preserves the layer natively — whenever it
  cannot be re-embedded faithfully: a rotation (text placement on the baked-in-rotation
  raster is deferred), a run outside WinAnsi (`PDFWriter.winAnsiWouldLose` — the same
  Latin-1 limit `escapePDFString` carries, so Cyrillic/CJK layers keep their crisp gs
  output rather than degrading to `?`), or a page that yields no runs. A post-compose
  re-extraction check (mirroring `OCREngine.validateOCROutput`) declines rather than ship a
  file that silently lost its text. The **residual**: a born-digital page that is
  raster-dominated (coverage ≥ threshold), near-bilevel, and carries WinAnsi-representable
  *visible* vector text would be rasterised by Rung 2 — accepted as narrow and gated by the
  gs race; no corpus document hits it.
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
- Output names are **reserved serially, one row at a time, as each file is added to
  the queue** (`QueueViewModel.add(_:)` → `reserve(for:)`, see
  `FileNaming.output(for:suffix:folder:reserving:)` in [Shared](shared.md)): a purely
  on-disk existence check races when two queued inputs share a basename, so allocation
  must happen on one thread first, against the reservation ledger already handed out
  to every row ahead of it — not merely a batch-start snapshot, since a row can be
  added mid-run (spec §6.5).
- **Rung 3 routes on `wantsMRC`** (`CompressEngine.compress`): a `.scanColour`
  document at any preset except `.maximumQuality` runs the gs pass first (unchanged —
  it is the D7 baseline), then attempts `mrcCompress`. Any MRC failure other than
  `CancellationError` declines to the gs output (D10) — the document is never worse
  off than before Rung 3 existed. The R2 structural sweep (`MRCClassifier.structure`)
  runs over every page before any rendering: one non-`.simpleSingleImage` page kills
  the whole attempt, because the fallback path rasterises and rasterising real text is
  destructive.
- **`wantsMRC`'s per-file opt-out only ever narrows, never widens** (`CompressEngine.compress`'s
  `rebuildScan: Bool?` parameter, spec §7): `nil` derives the decision exactly as if the row had
  never been touched; `false` forces the hybrid leg off regardless of classification; `true` still
  has to clear `.scanColour` and non-`.maximumQuality` — opting in can never reach a document or
  preset the classifier/D3 would otherwise refuse. `QueueViewModel` stores the row's choice in
  `overrides[id]?.rebuildScan` and threads it through every call site that needs the same
  three-way answer — the live compress, `CompressEstimator.analyse(_:mrcEligible:)`'s pricing, and
  `recompressPrediction(for:at:)`.
- **The estimator prices a rebuild-eligible `.scanColour` document off its own table, not the
  general one** (`CompressEstimator.predict`): `scanColourRebuildReduction` applies only when
  `mrcEligible && contentType == .scanColour && preset != .maximumQuality` — the same three-way
  test `CompressEngine.compress` runs for `wantsMRC` — else the estimate falls back to
  `baseReduction[contentType]` (or `typicalReduction` when analysis failed, flagged `isFallback`).
  Opting a row out of the rebuild (`rebuildScan == false`) therefore also switches which table
  prices it, not just what the engine ships.
- **MRC renders at the scan's native resolution, never above** (`CompressEngine.mrcCompress`
  and `fallbackJPEG` cap `maxDimension` at `MRCClassifier.sourceImageLongEdge`): the presets'
  `bilevelDPI` (300 balanced) over-renders a typical ~200-dpi scan, upsampling for no real
  detail while inflating every layer — the CCITT mask most of all (~2.25× at 300 vs 200 dpi).
  Capping at the source keeps text as crisp as the scan and is what lets the sharp
  (native-emitted) foreground fit the size budget. A sub-`minBilevelDPI` scan (its source
  below the floor) declines to gs rather than shipping a blocky rebuild.
- **D7 document gate, and R7's reversal: the LOSER is retained too** (`CompressEngine.compress`,
  `RowOutcome` in `Models/JobOutcome.swift`): a legitimate, validated hybrid (smaller than the
  input) is parked as a `RetainedVariant` regardless of which side of the gs comparison it lands
  on — not just when it wins. If it beats the gs output too, it ships (`shippedVariant: .mrc`) and
  the gs output (or, when gs itself was not smaller than the input, a copy of the untouched
  original — `RetainedVariant.kind == .original` is the marker; R6 forbids offering a
  larger-than-input file, and the UI labels that card "Original") is parked as the `runnerUp`. If
  gs still wins the size gate, the hybrid itself is retained instead and offered beside the gs
  winner — spec §5's R7-asymmetry reversal, because the consent sheet is about the *look* of the
  page, not only bytes. `VersionStore` (`RowVersions`, `EngineVariant`) is what turns that retained
  variant into the switch UI.
- **A finished row can be recompressed at a different preset without re-adding the
  file** (`QueueViewModel.recompressState(for:)`): switching the batch preset arms
  every finished row whose own preset differs — `.futile` if that preset already came
  back no-gain, `.instantSwitch` if a parked `previous` version already matches it
  (no re-run), else `.armed`. Pressing run serialises the armed rows through the
  engine directly, AFTER the normal queue phase finishes (`runRecompressPhase`), so
  the batch stays within one normal run's process width (R9's arming is disabled for
  the run's duration). A recompress always reads the ORIGINAL input, never the
  row's current output (D2). `VersionStore` keeps at most one parked `previous`
  version per row (D3) — arming a second recompress discards whichever `previous`
  the row already held.
- **`RunnerUpStore` is the one documented exception to "no persisted app state"**
  (spec R15): it caches the losing gs version on disk (`caches/Toolbox/runner-ups`) so
  the heavy-capsule popover's switch is instant. `sweepStale()` runs once, from
  `QueueViewModel.init` — effectively at launch because `RootView` constructs the
  `@StateObject` view model exactly once under the app's single `Window` scene (see
  [App](app.md)) — `removeAllOnDisk()` at quit (`AppDelegate.applicationWillTerminate`) — a crash
  between the two just leaves stale cache files, cleaned on the next launch.
  `switchVersions(shipped:runnerUp:)` exchanges file *content* via three moves (park →
  promote → demote), never rewriting either path, so a mid-switch crash restores the
  shipped file rather than losing it. If the cached runner-up has vanished by the time
  the user switches, `QueueViewModel.rerunForSwitch` honestly re-runs the job (R10)
  rather than failing silently.
- **MRC text sharpness is set by the foreground's *emitted* resolution, not the mask**
  (field-blur fix, 2026-07-24): the CCITT text mask is the foreground JPEG's PDF
  soft-mask, and a viewer resamples that mask to the foreground *image's* pixel grid.
  So a foreground emitted at its content resolution (`MRCSegmenter.fgDownsample` = 6,
  ≈50 dpi) dragged the razor-sharp mask down to 50 dpi and smeared every glyph — the
  shipped-but-blurry defect three attempts missed. `MRCPageEncoder.encode` now re-emits
  the (coarse, flat-filled, cheap) foreground at `MRCSegmenter.foregroundLayerScale` =
  ⅔ of the mask resolution (`resample`), which keeps composited text crisp while the
  smooth foreground JPEG still fits budget. `.bgDownsample` = 3 / `.fgDownsample` = 6 are
  now only *content* coarseness (block-average footprint); glyph shape is the mask's job.
  The foreground uses `colourLayer(…flatFill: true)` (masked-out regions get one global
  mean, not spread gradients — ~2× smaller JPEG); the background keeps spread-fill so it
  carries the *local* paper through glyph holes. `MRCVerifier.maxNormalisedError`
  = 0.33 (ink-weighted relative-error pass/fail threshold); `CompressEngine.maxMRCPages`
  = 400 (≈ `maxBilevelPages` / 3 — MRC holds three encoded layers per page and
  recomposes each to verify it, so its per-page peak is several times Rung 2's);
  `MRCClassifier.maxModerateChromaCoverage` = 0.115 (field-calibrated 2026-07-24:
  declines pale fine-pattern security backgrounds — guilloche — as `.chromaPattern`;
  it formally subsumes `maxColourCoverage`, kept as belt-and-braces; see
  `.claude/DECISIONS.md`, 2026-07-24 chroma-gate entry, for the measured basis).
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

- Modules: [Services](services.md), [Shared](shared.md), [Models](models.md), [App](app.md),
  [OCR](ocr.md) (shared `QueueViewModel`/queue)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §5, `.claude/specs/20260723-mrc-rung3.md`
