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
two-tone, falling back to Rung 1 on any failure or no gain. Also estimates the output
size before running and drives the batch UI. Rung 3 (MRC, colour scans) is not built.

## Key files

| File | Role |
|------|------|
| `Sources/PDFToolbox/Compress/CompressEngine.swift` | `CompressEngine.compress(_:preset:to:progress:)` — stage/run/validate/atomically-place one file; routes `.scanBilevel` documents through Rung 2 first (`bilevelCompress`) |
| `Sources/PDFToolbox/Compress/BilevelScan.swift` | `BilevelScan.binarise(_:)` — near-bilevel gate (`isNearBilevel`) + Otsu-threshold reduction to 1-bit `/DeviceGray` |
| `Sources/PDFToolbox/Compress/CCITTEncoder.swift` | `CCITTEncoder.encode(_:)` — CCITT Group 4 via an in-memory TIFF (ImageIO), strip lifted back out for `/CCITTFaxDecode` |
| `Sources/PDFToolbox/Compress/BilevelPDFComposer.swift` | `BilevelPDFComposer.compose(pages:)` — builds a fresh classic-xref PDF whose pages are CCITT image XObjects |
| `Sources/PDFToolbox/Compress/CompressEstimator.swift` | `CompressEstimator.estimate(_:preset:)` — time-boxed, parse-only pre-run size prediction |
| `Sources/PDFToolbox/Compress/CompressViewModel.swift` | `@MainActor` state: queue, preset, output folder, per-job estimate overlay |
| `Sources/PDFToolbox/Compress/CompressView.swift` | Drop zone, file rows, preset picker, output-folder row, run/cancel |

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

## Gotchas

- `CompressPreset.gsArguments()` figures (DPI, `/ebook` etc.) are a **concrete
  provisional baseline**, not corpus-tuned — expect them to change without an
  architecture change.
- `CompressEstimator`'s reduction percentages are heuristic (byte-density-per-page
  proxy for image payload), not measured against a real corpus; `isFallback` flags
  when the time-box (0.5 s) was exceeded or analysis failed, falling back to a flat
  per-preset typical range.

## Extension points

- A future Rung 3 (MRC, colour scans) would branch inside `CompressEngine.compress`
  on `PDFService.classify`'s `.scanColour` result, alongside the existing Rung-1/2 paths.
- Per-page (rather than whole-document) Rung 2 routing is spec'd for v1.1, not v1.

## Related

- Modules: [Services](services.md), [Shared](shared.md), [Models](models.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §5
