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
| `Sources/PDFToolbox/OCR/OCREngine.swift` | `OCREngine.ocr(_:to:options:progress:)` — per-page skip/render/recognise/embed loop |
| `Sources/PDFToolbox/OCR/VisionOCR.swift` | `VisionOCR.recognise(_:options:)` — wraps `VNRecognizeTextRequest`, returns Vision-normalised boxes verbatim |
| `Sources/PDFToolbox/OCR/OCROptions.swift` | `OCROptions` (accuracy, languages) + `Accuracy` enum |
| `Sources/PDFToolbox/OCR/OCRViewModel.swift` | `@MainActor` state: queue, options, `OCREngine`; pins batch concurrency to 2 |
| `Sources/PDFToolbox/OCR/OCRView.swift` | Drop zone, file rows, options panel, run/cancel |

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
- **Batch concurrency is pinned to 2** in `OCRViewModel.run` — each in-flight file
  holds one 300-DPI page raster, so 2 bounds memory while still overlapping I/O and
  recognition (deliberately not `SystemInfo.performanceCoreCount`, unlike Compress).
- Output names are pre-allocated serially before the concurrent run starts, same
  pattern and same reason as Compress — see [Shared](shared.md) `FileNaming`.
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

- Modules: [Services](services.md) (PDFWriter, OpenGuard, OutputValidator), [Shared](shared.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §6
