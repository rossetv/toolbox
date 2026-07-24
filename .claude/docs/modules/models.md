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
| `Sources/Toolbox/Models/ToolJob.swift` | `ToolJob` — one queued file: id, url, `state`, `resultURL`, `alternateURL` (Rung-3 runner-up), `estimate`, `mrcReport` (spec §6 debugging record) |
| `Sources/Toolbox/Models/JobOutcome.swift` | `JobOutcome` (compressed/noGain/ocrAdded/alreadySearchable/`compressedHeavy(before:after:runnerUpBytes:)`) + `JobState` (queued/analysing/running/done/failed) |
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
- `JobOutcome.compressedHeavy`'s `runnerUpBytes` is the demoted gs version's size —
  the job's `resultURL` holds whichever version is currently shipped and `alternateURL`
  the cached runner-up (`RunnerUpStore`, see [Compress](compress.md)); a switch swaps
  file *content* between the two paths, so both fields stay fixed for the job's life.
- `PDFService.classify` never actually returns `.mixedColour` today — only
  `.bornDigital`, `.scanBilevel` and `.scanColour` are reachable from its current
  logic. `CompressEstimator` still carries a weight for it (seeding a future,
  finer-grained classifier), so the case stays in the enum.

## Related

- Modules: [Compress](compress.md), [Shared](shared.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §5.1, §5.2
