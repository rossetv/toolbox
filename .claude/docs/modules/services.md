<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every path, command, and constant below must
be verified against the code before writing; on contradiction, fix here at
once. Unknown fact → omit the section, never guess.
NEVER cite a line number (no `file.sh:234`, no bare `(:234)`, no ranges): any edit
above it rots the citation, and re-numbering then eats the whole maintenance budget.
Cite the file plus a stable, greppable anchor — a function, variable, constant or
check name: `scripts/kb-gate-lib.sh` (`review_key()`). Verify the anchor with grep. -->
↑ [INDEX](../../INDEX.md)

# Module: Services

## Purpose

Everything that touches an untrusted PDF or the sandboxed subprocess: the gs runner +
its seatbelt profile, PDF inspection/rasterisation, encrypted/corrupt detection,
output re-validation, and the hand-written PDF incremental-update writer. Both
[Compress](compress.md) and [OCR](ocr.md) depend on this layer; it depends on neither.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/Services/GhostscriptRunner.swift` | `GhostscriptRunner.run(arguments:readPaths:writePaths:onProgress:)` — the only way gs is ever invoked |
| `Sources/Toolbox/Services/SeatbeltProfile.swift` | `SeatbeltProfile.profile(gsPath:readPaths:writePaths:)` — builds the SBPL string |
| `Sources/Toolbox/Services/PDFService.swift` | `pageCount`, `classify`, `pageHasText`, `renderSample`, `render` — page-sampled inspection, per-page render/release |
| `Sources/Toolbox/Services/OpenGuard.swift` | `OpenGuard.inspect(_:)` — up-front encrypted/corrupt detection, shared by both engines |
| `Sources/Toolbox/Services/OutputValidator.swift` | `OutputValidator.validate(input:output:samplePages:)` — page-count + per-sample-page ink-retention check |
| `Sources/Toolbox/Services/PDFWriter.swift` | `PDFWriter.appendTextLayer(to:output:pageText:geometry:)` — hand-written PDF incremental update; owns the Vision→PDF coordinate transform |
| `Sources/Toolbox/Services/PDFSyntax.swift` | `PDFSyntax` — byte-level PDF lexical scanner (PDF 32000-1 §7.2–§7.3): token/dictionary/array/string boundaries, name-escape decoding, bounds-checked integer/reference parsing; `PDFWriter`'s only means of reading PDF structure |
| `Sources/Toolbox/Services/PDFFlate.swift` | `PDFFlate.inflate(_:limit:)` — bounded `FlateDecode` (zlib) inflate; used by `PDFWriter` to read compressed object streams |

## Invariants

- **`(deny default)` + `(allow process-exec* (literal <gsPath>))` are both essential
  and load-bearing** (`SeatbeltProfile.profile` doc comment): SBPL defaults to *allow*,
  so without `(deny default)` the file/network scoping confines nothing; without the
  literal `process-exec*` grant, `sandbox-exec` refuses to exec gs at all
  (`execvp Operation not permitted`). Removing either silently breaks containment or
  breaks gs launching — verified empirically, not just by string inspection
  (`Tests/ToolboxTests/SeatbeltRunTests.swift`: `testProfileContainsRequiredClauses`,
  `testRealSandboxedCompressionProducesSmallerValidPDF`, `testWriteOutsideScopeIsDenied`).
- **Every gs invocation goes through `sandbox-exec`, never a bare `Process`** —
  `GhostscriptRunner.runBlocking` hard-codes `/usr/bin/sandbox-exec` as the executable
  and always prepends `-dSAFER -dBATCH -dNOPAUSE`.
- **All paths handed to the profile must be canonical** (`URL.canonical`, see
  [Shared](shared.md) `CanonicalPath.swift`): the kernel resolves gs's file accesses to
  their real `/private/var`/`/private/tmp` paths, so a scope entry left as `/var/…`
  silently fails to match and the access is denied.
- **The sandboxed gs child gets a private, in-scope scratch dir via `TMPDIR`**
  (`GhostscriptRunner.runBlocking`): under `(deny default)` the system temp dir is out
  of scope, and gs's `pdfwrite` device needs scratch space to write to.
- **Pipe draining runs concurrently with the process, never after** — both stdout and
  stderr are drained to EOF on background threads while `waitUntilExit` blocks;
  mixing a `readabilityHandler` with `readDataToEndOfFile` would deadlock (its
  dispatch source consumes EOF and the later blocking read never returns) — see the
  comment at `GhostscriptRunner.runBlocking`'s `ioGroup`/`ioQueue` setup.
- **A watchdog terminates a runaway gs at `wallClockTimeout`** (default 300 s); a
  process that exits cleanly (status 0) exactly at the deadline is a success, never a
  timeout — the check requires both `didTimeout` **and** a non-zero termination status.
- `OpenGuard.inspect` gates on `isEncrypted && isLocked`, not `isEncrypted` alone: an
  owner-password-only PDF (no user password) opens usable and must not be treated as
  locked.
- `OutputValidator.validate` compares each sampled output page's ink ratio against the
  **same input page's** ink ratio (not an absolute floor) — a legitimately sparse page
  (a few lines, wide margins) would otherwise be falsely rejected; pages with no real
  input content (`inInk < contentFloor = 0.02`) are skipped entirely.
- `PDFWriter.appendTextLayer` never rewrites the original bytes — it only appends new
  objects, a new classic xref section, and a trailer with `/Prev` pointing at the
  previous `startxref`. The original page's image XObject streams are untouched, so
  the rendered appearance is provably unchanged (still re-checked by
  `OutputValidator`).
- **`PDFSyntax` scans bytes, never `Character`s**: Swift collapses a CR byte followed
  by an LF byte into one extended grapheme cluster that matches neither `"\r"` nor
  `"\n"`, so a `String`-based scanner misses PDF's CRLF token separator and can write
  a duplicate key. Every function is index-agnostic (works from the collection's own
  bounds), so a slice of a larger buffer scans without rebasing.
- **`PDFSyntax.dictLookup` distinguishes `.absent` from `.unparseable`** (`DictLookup`
  enum) — callers that go on to *modify* a dictionary must treat `.unparseable` as an
  error rather than as "key not there": conflating the two risks inserting a second
  copy of a key that was actually present, which makes the whole dictionary's meaning
  undefined (PDF 32000-1 §7.3.7). `dictValue`/`dictName`/`dictInt`/`dictRef` are the
  read-only convenience wrappers that collapse both cases to nil.
- **`PDFSyntax.parseInt` refuses integers above `maxPlausibleInteger` (2^40)**: a PDF may
  name object `9223372036854775807`, which *is* `Int.max`, so an unbounded `Int(digits)`
  parses it successfully and the writer's first `+= 1` on it then traps and crashes —
  reachable from a few dozen bytes of untrusted input. The failure mode is a *successful*
  parse, not an overflow: Swift's `Int(String)` returns nil above `Int.max` rather than
  clamping to it, so a nil-check alone would not catch this. Nothing legitimate in a PDF
  needs a value this large.
- **`PDFFlate.inflate` is budget-bounded, never "inflate and see"**: a stream's
  compressed size says nothing about its expanded size, so decoding an untrusted
  object stream without a ceiling is a decompression bomb. `PDFWriter` spends one
  budget (`maxObjectStreamBytes`, 64 MiB) across the **whole file**, not per stream,
  so many small object streams can't add up past the ceiling either.

## Input-scaled bounds

The register of every named bound on an allocation, recursion or walk that an untrusted
PDF can scale. `CODE_GUIDELINES.md` §4.4 is the rule (new code of this kind ships with a
constant and a test that exercises it) and points here for the inventory, so the list
lives beside the code rather than rotting in the law. It is deliberately cross-module: the
two render caps belong to the engines, not to Services, but they are the same class of
bound and are easiest to keep honest in one table.

| Bound | Guards against | Where |
|---|---|---|
| `maxInputBytes` | one OCR job taking the machine | `Sources/Toolbox/Services/PDFWriter.swift` |
| `maxObjects` | an index that scales with file size, not page count | `Sources/Toolbox/Services/PDFWriter.swift` |
| `maxPageTreeDepth` / `maxPageTreeNodes` | stack overflow / unbounded walk from a crafted page tree | `Sources/Toolbox/Services/PDFWriter.swift` |
| `maxObjectStreamBytes` (spent across the whole file, not per stream) | decompression bombs spread across many `/ObjStm` | `Sources/Toolbox/Services/PDFWriter.swift` (`indexObjectStreams`) |
| `PDFFlate.inflate` + `maxCompressedToOutputRatio` | output bombs, and copying a whole file as "compressed" input | `Sources/Toolbox/Services/PDFFlate.swift` |
| `maxRasterPixels` | a hostile `/MediaBox` (the spec's largest legal page is ~14 GB at 300 DPI) | `Sources/Toolbox/OCR/OCREngine.swift` |
| `maxBilevelPixels` | the same, on the Rung-2 render | `Sources/Toolbox/Compress/CompressEngine.swift` |
| `outputTailLimit` (applied to stdout **and** stderr) + `failureMessage` | unbounded attacker-influenced text retained and shown | `Sources/Toolbox/Services/GhostscriptRunner.swift`, `Sources/Toolbox/Compress/CompressEngine.swift` |
| `wallClockTimeout` | a hung or runaway gs child | `Sources/Toolbox/Services/GhostscriptRunner.swift` |

Both gs streams are bounded, not just stderr: a bogus `-sDEVICE` puts its whole diagnosis
on stdout with nothing on stderr at all (`GhostscriptRunner.drainTail`, applied to both
pipes; `CompressEngine.failureMessage`'s doc comment records the measurement).

## Gotchas

- **Object-stream (`/ObjStm`) PDFs are now OCR-able.** `PDFWriter` indexes every
  packed object via `PDFSyntax` + `PDFFlate.inflate` (`indexObjectStreams`) and
  supersedes one by emitting an **uncompressed top-level object of the same number**
  in the appended section — the newest cross-reference entry wins (PDF 32000-1
  §7.5.6), so the object stream itself is never rewritten. An object stream this
  can't read (an unsupported filter, a `/DecodeParms` predictor, a truncated body) is
  skipped rather than fatal; `.unsupportedStructure` only surfaces if the *skipped*
  stream held an object the writer actually needed. Compress is unaffected either way
  (it never parses PDF structure directly — gs does).
- `PDFWriter`'s text layer uses base-14 Helvetica + WinAnsi only — non-Latin-1
  characters in recognised text become `?` (`PDFWriter.escapePDFString`); a conscious
  v1 deferral, not a bug.
- `GhostscriptRunner`'s test-seam initialiser (`init(gsURL:wallClockTimeout:)`) exists
  so tests can point at an arbitrary gs path, but the test suite itself always uses
  the bundled gs via `Bundle.main` (`init()`) — a gs binary under a TCC-protected
  location would stall a non-interactive process's `open()` on an unanswerable TCC
  prompt.
- `-dSAFER` is asserted explicitly on every invocation even though it has been gs's
  default since 9.50 — defence in depth, not redundant given the CVE history this
  sandbox exists to mitigate.

## Related

- Modules: [Compress](compress.md), [OCR](ocr.md), [Shared](shared.md) (`CanonicalPath`)
- Specs: `.claude/specs/20260722-pdf-toolbox-v1.md` §5.4, §11.4
- Decisions: 2026-07-22 — Ghostscript engine + AGPL; 2026-07-22 — seatbelt sandbox for every gs invocation
