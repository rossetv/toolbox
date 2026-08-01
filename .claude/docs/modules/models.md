<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every path, command, and constant below must
be verified against the code before writing; on contradiction, fix here at
once. Unknown fact → omit the section, never guess.
NEVER cite a line number (no `file.sh:234`, no bare `(:234)`, no ranges): any edit
above it rots the citation, and re-numbering then eats the whole maintenance budget.
Cite the file plus a stable, greppable anchor — a function, variable, constant or
check name: `scripts/kb-gate-lib.sh` (`review_key()`). Verify the anchor with grep. -->
↑ [INDEX](../../INDEX.md)

# Module: Models

## Purpose

Tool-agnostic value types shared across the app: the job lifecycle, compression
presets, content classification, and size estimates. No behaviour, no I/O.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/Models/ToolJob.swift` | `ToolJob` — one queued file: id, url (mutable for `ToolQueue.rebind(_:to:)` alone), `state`, `resultURL`, `alternateURL` (the retained variant), `estimate`, `mrcReport` (spec §6 debugging record) |
| `Sources/Toolbox/Models/JobOutcome.swift` | The pass's result vocabulary: `RowOutcome` (the compound per-file result — `originalBytes`/`finalBytes`, a `CompressOutcome?` and an `OCROutcome?` side by side, `shippedVariant`, `runnerUp`), `CompressOutcome` (compressed/noGain/skipped), `OCROutcome` (added/alreadySearchable/tooFaint/cancelled/failed), `RetainedVariant`, `RowProblem` (locked/missing/unreadable/compressFailed) + `JobState` (queued/analysing/running/done/failed) |
| `Sources/Toolbox/Models/CompressPreset.swift` | `CompressPreset` (maximumQuality/balanced/smallestSize) — `gsArguments()` builds the tuned gs flag set |
| `Sources/Toolbox/Models/PDFContentType.swift` | `PDFContentType` (bornDigital/mixedColour/scanColour/scanBilevel) |
| `Sources/Toolbox/Models/SizeEstimate.swift` | `SizeEstimate` (predictedBytes, `Confidence`, isFallback) |

## Invariants

- `CompressPreset.gsArguments()` is the **only** place gs tuning flags are assembled —
  `CompressEngine` appends only `-sOutputFile=` and the input path to this list.
- `PDFContentType`'s colour/bilevel split is classified by `PDFService.classify`
  ([Services](services.md)) and **is** consumed for routing: `.scanBilevel` routes
  through Rung 2 (binarise + CCITT G4) first, falling back to Rung 1 gs on any
  failure or no gain; `.scanColour` on Balanced/Smallest routes through Rung 3 (MRC),
  weighed against the Rung-1 gs output; `.bornDigital` and any preset-excluded case go
  straight to Rung 1 (see [Compress](compress.md)).
- **`RowOutcome` reports the two legs side by side, never as alternatives** — one file
  can be both compressed and made searchable, so `compress`/`ocr` are independent
  optionals and nil means "that verb was off for this row". `finalBytes` is the
  DELIVERED file's size: the engine sets the compress artefact's, and the queue's commit
  step re-stats it after the OCR leg, so `grew` is only meaningful once committed.
- **`runnerUp`'s presence, not `shippedVariant`, is what says a second variant was
  retained** (spec §5's R7 reversal): a legitimate hybrid is parked whichever side of the
  size gate it lands on, and that presence is what triggers the consent sheet and the
  versions capsule. The job's `resultURL` holds whatever is currently shipped and
  `alternateURL` the parked file (`RunnerUpStore`, see [Compress](compress.md)); a switch
  swaps file *content* between the two paths, so both fields stay fixed for the job's life.
- **`RowOutcome.isDegraded` is not failure** — a rescued row, a `tooFaint` or cancelled
  read, and a read that failed after delivery all warn while keeping their delivered
  file, because the Problems footer's promise that failed files were not touched at all
  must stay true. See [Queue](queue.md).
- `PDFService.classify` never actually returns `.mixedColour` today — only
  `.bornDigital`, `.scanBilevel` and `.scanColour` are reachable from its current
  logic. `CompressEstimator` still carries a weight for it (seeding a future,
  finer-grained classifier), so the case stays in the enum.

## Related

- Modules: [Queue](queue.md) (the pass that produces every `RowOutcome`),
  [Compress](compress.md), [Shared](shared.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §5.1, §5.2
