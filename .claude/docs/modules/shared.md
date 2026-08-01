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

Infrastructure the queue and both legs reuse: the generic batch runner, output-naming
collision avoidance, path canonicalisation, the file/folder picker, the blocking-work
bridge, and the performance-core count.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/Shared/ToolQueue.swift` | `ToolQueue` — `@MainActor` batch runner: per-job state machine, bounded concurrency, `run(_:maxConcurrent:skipping:)`'s exclusion set, cancellation, `rebind(_:to:)`; `JobResult` also carries `alternateURL`/`mrcReport` through to the job for Rung 3 |
| `Sources/Toolbox/Shared/OffloadBlocking.swift` | `offloadBlocking(_:)` — runs a synchronous throwing closure on a `.userInitiated` global queue and suspends until it finishes; the shared bridge used by `CompressEngine`'s OCR-layer write/validate pass and `OCREngine.ocr`'s render/recognise step |
| `Sources/Toolbox/Shared/FileNaming.swift` | `FileNaming.output(for:suffix:folder:reserving:)` — collision-free `<name>-<suffix>.pdf` naming |
| `Sources/Toolbox/Shared/CanonicalPath.swift` | `URL.canonical` / `URL.canonicalPath` — C `realpath`-based canonicalisation |
| `Sources/Toolbox/Shared/SystemInfo.swift` | `SystemInfo.performanceCoreCount` — `hw.perflevel0.logicalcpu` via `sysctlbyname` |
| `Sources/Toolbox/Shared/FilePicker.swift` | `FilePicker.choosePDFs()` / `.chooseFolder()` — `NSOpenPanel`-based file/folder selection |

## Invariants

- **`ToolQueue`'s job body contract**: the closure passed to `run(_:maxConcurrent:skipping:)`
  must *suspend* on its blocking work, never block a cooperative-pool thread — the
  concurrency cap is only real if every body honours this. `offloadBlocking(_:)` is the
  shared bridge for this (`CompressEngine`'s text-layer write/validate pass,
  `OCREngine.ocr`'s render/recognise step); a `Task.checkCancellation()` inside its
  closure is a silent no-op (the closure runs on a plain GCD queue, no current task), so
  callers check cancellation after the `await` returns, not inside it.
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
- **`FileNaming.output(for:suffix:folder:reserving:)` must be called serially, on the
  main actor, against a ledger of everything already handed out** — `QueueViewModel`
  reserves each row's name as the file is ADDED (`reserveDelivery(suffix:for:)` over
  `reservedKeys(excluding:)`, see [Queue](queue.md)), not at run start, which is what
  lets a file be dropped in mid-run. A purely on-disk `fileExists` check races under
  concurrency: two queued inputs sharing a basename (from different source folders,
  same output folder) would otherwise both resolve to the same candidate name and the
  second job's atomic rename would fail. The `reserved` set threaded through each call
  is what prevents this.
- **`FilePicker` uses `NSOpenPanel`, not `.fileImporter`**: two `.fileImporter`
  modifiers attached to the same SwiftUI view (one for input PDFs, one for the output
  folder) conflict on macOS and neither reliably presents — how the app first shipped
  with a "Choose Files…" button that did nothing. `NSOpenPanel.runModal()` returns
  synchronously, so `choosePDFs`/`chooseFolder` are plain `@MainActor` functions with
  no callback plumbing.

## Related

- Modules: [Queue](queue.md) (the app's only caller of `ToolQueue.run`), [Compress](compress.md),
  [OCR](ocr.md), [Services](services.md)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §4 ("Concurrency"), §5.4 ("Atomicity")
