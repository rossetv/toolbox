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

The Compress tool: routes every input through tuned Ghostscript `pdfwrite` (Rung 1 —
the only rung built), estimates the output size before running, and drives the batch
UI. No content-based routing to a different engine exists yet.

## Key files

| File | Role |
|------|------|
| `Sources/PDFToolbox/Compress/CompressEngine.swift` | `CompressEngine.compress(_:preset:to:progress:)` — stage/run/validate/atomically-place one file |
| `Sources/PDFToolbox/Compress/CompressEstimator.swift` | `CompressEstimator.estimate(_:preset:)` — time-boxed, parse-only pre-run size prediction |
| `Sources/PDFToolbox/Compress/CompressViewModel.swift` | `@MainActor` state: queue, preset, output folder, per-job estimate overlay |
| `Sources/PDFToolbox/Compress/CompressView.swift` | Drop zone, file rows, preset picker, output-folder row, run/cancel |

## Invariants

- **All content types route to Rung-1 gs in v1** (`CompressEngine`'s doc comment: "A
  content router seam is present … Rungs 2/3 slot in later"). `PDFContentType`'s
  colour/bilevel split exists to seed that future routing — it is not consumed by
  `CompressEngine` today.
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

- A future Rung 2/3 native scan pipeline would branch inside `CompressEngine.compress`
  on `PDFService.classify`'s result, alongside the existing Rung-1 gs path.

## Related

- Modules: [Services](services.md), [Shared](shared.md), [Models](models.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §5
