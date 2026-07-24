<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every path, command, and constant below must
be verified against the code before writing; on contradiction, fix here at
once. Unknown fact → omit the section, never guess.
NEVER cite a line number (no `file.sh:234`, no bare `(:234)`, no ranges): any edit
above it rots the citation, and re-numbering then eats the whole maintenance budget.
Cite the file plus a stable, greppable anchor — a function, variable, constant or
check name: `scripts/kb-gate-lib.sh` (`review_key()`). Verify the anchor with grep. -->
↑ [INDEX](../../INDEX.md)

# Module: Shared

## Purpose

Infrastructure both tools reuse: the generic batch runner, output-naming collision
avoidance, path canonicalisation, performance-core count, and logging categories.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/Shared/ToolQueue.swift` | `ToolQueue` — `@MainActor` batch runner: per-job state machine, bounded concurrency, cancellation; `JobResult` also carries `alternateURL`/`mrcReport` through to the job for Rung 3 |
| `Sources/Toolbox/Shared/FileNaming.swift` | `FileNaming.output(for:suffix:folder:reserving:)` — collision-free `<name>-<suffix>.pdf` naming |
| `Sources/Toolbox/Shared/CanonicalPath.swift` | `URL.canonical` / `URL.canonicalPath` — C `realpath`-based canonicalisation |
| `Sources/Toolbox/Shared/SystemInfo.swift` | `SystemInfo.performanceCoreCount` — `hw.perflevel0.logicalcpu` via `sysctlbyname` |
| `Sources/Toolbox/Shared/Log.swift` | `Log.compress`/`.ocr`/`.queue`/`.general` — unified-logging `Logger` categories |
| `Sources/Toolbox/Shared/FilePicker.swift` | `FilePicker.choosePDFs()` / `.chooseFolder()` — `NSOpenPanel`-based file/folder selection |

## Invariants

- **`ToolQueue`'s job body contract**: the closure passed to `run(_:maxConcurrent:)`
  must *suspend* on its blocking work, never block a cooperative-pool thread — the
  concurrency cap is only real if every body honours this (both `CompressEngine.compress`
  and `OCREngine.ocr` bridge their blocking work via `withCheckedContinuation` /
  `withCheckedThrowingContinuation` for exactly this reason).
- **A throw inside the job body fails only that job** (`.failed(message)`); the batch
  continues. A `CancellationError` returns the job to `.queued`, relying on the
  engine's atomic-write contract to guarantee no partial output was left behind.
- **`ToolQueue.run` uses a sliding window**, launching the next queued job as each
  finishes — never "add all `maxConcurrent` tasks up front", which would ignore the
  cap once any finishes early.
- **`URL.canonical` uses C `realpath`, not `resolvingSymlinksInPath()`** —
  `resolvingSymlinksInPath()` does **not** resolve `/var` → `/private/var` or
  `/tmp` → `/private/tmp`, which the kernel does when resolving a sandboxed child's
  file accesses. A seatbelt profile scope entry built from the non-canonical form
  silently fails to match and the access is denied — see
  [Services](services.md) (`SeatbeltProfile`). For a not-yet-existing leaf path (e.g.
  an output temp file), `canonicalPath` canonicalises the existing parent directory
  and re-appends the leaf.
- **`FileNaming.output(for:suffix:folder:reserving:)` must be called serially for a
  whole batch, before the concurrent run starts** — both `CompressViewModel.compress`
  and `OCRViewModel.run` pre-allocate every job's output name on one thread first. A
  purely on-disk `fileExists` check races under concurrency: two queued inputs sharing
  a basename (from different source folders, same output folder) would otherwise both
  resolve to the same candidate name and the second job's atomic rename would fail.
  The `reserved` set threaded through each call is what prevents this.
- **`FilePicker` uses `NSOpenPanel`, not `.fileImporter`**: two `.fileImporter`
  modifiers attached to the same SwiftUI view (one for input PDFs, one for the output
  folder) conflict on macOS and neither reliably presents — how the app first shipped
  with a "Choose Files…" button that did nothing. `NSOpenPanel.runModal()` returns
  synchronously, so `choosePDFs`/`chooseFolder` are plain `@MainActor` functions with
  no callback plumbing.

## Related

- Modules: [Compress](compress.md), [OCR](ocr.md), [Services](services.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §4 ("Concurrency"), §5.4 ("Atomicity")
