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
| `Sources/PDFToolbox/Models/ToolJob.swift` | `ToolJob` — one queued file: id, url, `state`, `resultURL`, `estimate` |
| `Sources/PDFToolbox/Models/JobOutcome.swift` | `JobOutcome` (compressed/noGain/ocrAdded/alreadySearchable) + `JobState` (queued/analysing/running/done/failed) |
| `Sources/PDFToolbox/Models/CompressPreset.swift` | `CompressPreset` (maximumQuality/balanced/smallestSize) — `gsArguments()` builds the tuned gs flag set |
| `Sources/PDFToolbox/Models/PDFContentType.swift` | `PDFContentType` (bornDigital/mixedColour/scanColour/scanBilevel) |
| `Sources/PDFToolbox/Models/SizeEstimate.swift` | `SizeEstimate` (predictedBytes, `Confidence`, isFallback) |

## Invariants

- `CompressPreset.gsArguments()` is the **only** place gs tuning flags are assembled —
  `CompressEngine` appends only `-sOutputFile=` and the input path to this list.
- `PDFContentType`'s colour/bilevel split is classified by `PDFService.classify`
  ([Services](services.md)) but **not currently consumed for routing** — every type
  compresses via Rung-1 gs today (see [Compress](compress.md)). The split exists to
  seed a future Rung 2/3 native scan pipeline.

## Related

- Modules: [Compress](compress.md), [Shared](shared.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §5.1, §5.2
