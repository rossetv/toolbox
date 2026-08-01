<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every path, command, and constant below must
be verified against the code before writing; on contradiction, fix here at
once. Unknown fact → omit the section, never guess.
NEVER cite a line number (no `file.sh:234`, no bare `(:234)`, no ranges): any edit
above it rots the citation, and re-numbering then eats the whole maintenance budget.
Cite the file plus a stable, greppable anchor — a function, variable, constant or
check name: `scripts/kb-gate-lib.sh` (`review_key()`). Verify the anchor with grep. -->
↑ [INDEX](../../INDEX.md)

# Module: OCR

## Purpose

The OCR tool: adds an invisible, selectable text layer to image-only pages using
on-device Apple Vision, page by page, then hands the recognised text to
`PDFWriter` (see [Services](services.md)) to embed.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/OCR/OCREngine.swift` | `OCREngine.ocr(_:to:options:progress:)` — per-page skip/render/recognise/embed loop, kept for its single-shot callers; the queue's own per-file body instead calls the two halves of the `OCRing` protocol this file also declares — `recognise(_:options:progress:)` and `append(_:to:output:)` — separately (see Invariants) |
| `Sources/Toolbox/OCR/VisionOCR.swift` | `VisionOCR.recognise(_:options:)` — wraps `VNRecognizeTextRequest`, returns Vision-normalised boxes verbatim |
| `Sources/Toolbox/OCR/OCROptions.swift` | `OCROptions` (accuracy, languages) + `Accuracy` enum |
| `Sources/Toolbox/Queue/QueueViewModel.swift` | `@MainActor` state for the **whole queue** — Compress and OCR share one view model and one job list (see [Compress](compress.md) for its Compress-specific surface); the OCR-specific piece is `appendLayer(_:using:...)`, which drives the `recognise`/`append` split below. Formerly the standalone `OCR/OCRViewModel.swift`, folded in when Compress and OCR became one queue |
| `Sources/Toolbox/Queue/QueueView.swift`, `QueueRowsView.swift`, `OCRPopover.swift` | Drop zone, file rows, the OCR options popover, run/cancel — the unified queue UI that replaced `OCR/OCRView.swift` |

## Invariants

- **Per-page skip**: a page with any extractable text (`PDFService.pageHasText`) is
  left alone; only image-only pages are rendered + recognised. If every page already
  had text, the job returns `.alreadySearchable` and nothing is written.
- **Render is per-page, upright** (`OCREngine.renderUpright`, 300 DPI): uses
  `PDFPage.thumbnail`, which honours `/Rotate`, unlike `PDFService.render` (which
  renders the unrotated media box and is deliberately not reused here).
- **`VisionOCR` never maps coordinates** — it returns Vision's normalised boxes
  (bottom-left origin, 0…1) verbatim; `PDFWriter` alone owns the transform into PDF
  user space (rotation + mediaBox origin).
- **Recognition and delivery are two separate steps, because one recognition serves
  every variant a job ships** (`OCRing` protocol, `Sources/Toolbox/OCR/OCREngine.swift`;
  spec §6.4): `QueueViewModel.runPass` calls `ocrEngine.recognise(_:options:progress:)`
  once per job to get a `RecognisedDocument`, then `appendLayer` (wrapping
  `ocrEngine.append(_:to:output:)`) re-embeds that same result onto whichever variant
  needs it — the row's compressed delivery, and again onto a switched-to version later
  (`useVersion`/`rerunForSwitch`) — rather than re-running Vision for each.
- **Batch concurrency is P-core-wide; the OCR cap moved, it did not die**: Compress and
  OCR share one queue and one run (`QueueViewModel.compress` → `queue.run`), the batch
  defaulting to `SystemInfo.performanceCoreCount` in `ToolQueue.run` — but the OCR LEG
  is still bounded to two in flight, now inside the view model
  (`QueueViewModel.ocrConcurrency` = 2, `acquireOCRSlot`/`releaseOCRSlot`, taken in
  `runOCRLeg` and the recompress path) for the same raster/recognised-runs memory
  reason the old `OCRViewModel.run` pin carried.
- Output names are reserved serially, one row at a time, as each file is added to the
  queue (`QueueViewModel.add(_:)` → `reserve(for:)`), same pattern and same reason as
  Compress — see [Compress](compress.md) and [Shared](shared.md) `FileNaming`.
- **Non-Latin scripts are a known v1 limitation**: the embedded text layer uses base-14
  Helvetica + WinAnsi (`PDFWriter`), so CJK/Arabic recognised text degrades to `?`
  per glyph (`PDFWriter.escapePDFString`) — invisible, so it doesn't affect the
  rendered page, only text selection/search/copy.

## Gotchas

- `OCREngine.ocr` throws `OCRError.corrupt` if the document opens with zero pages —
  distinct from `OpenGuard`'s own corrupt/encrypted checks, which run first.
- A blank scanned page (Vision finds nothing) still counts toward `ocrPages` in the
  result summary even though it contributes no text layer.

## Related

- Modules: [Services](services.md) (PDFWriter, OpenGuard, OutputValidator), [Shared](shared.md),
  [Compress](compress.md) (shared `QueueViewModel`/queue), [Models](models.md) (`OCROutcome` in
  `RowOutcome`)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §6
