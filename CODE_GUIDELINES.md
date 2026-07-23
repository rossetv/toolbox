# Code Guidelines — PDF Toolbox

The law for code in this repository, for human and AI contributors alike. It is written
to be cited: a reviewer rejecting a change quotes the rule by number ("violates §4.2").
Every rule traces to a real defect found in this codebase or a real invariant it depends
on — nothing here is speculative, and nothing is generic Swift style you could get from
any style guide.

Related law, not duplicated here:

- `DESIGN.md` — the visual language. UI work conforms to it (§8.4).
- `.claude/GATES.md` — the runbook of commands that define "done". This document says how
  to write the code; that one says how to prove it.

Citations name a file plus a stable, greppable anchor (a function, type or constant),
never a line number — line numbers rot on every edit above them. Follow the same
convention when adding to this document.

## §1 Authority and scope

**§1.1 — These rules bind every change.** "It's a small fix" is not an exemption; most of
the defects behind this document were small fixes.

**§1.2 — Rules are added freely, removed reluctantly.** A new class of defect earns a new
rule. Removing or weakening a rule is the repository owner's call, never a contributor's
convenience.

**§1.3 — A fixed bug's siblings are your bug too.** When you fix a defect, hunt the rest
of its class before you close it. The `/Resources`-shadowing fix in `PDFWriter` handled
the inheritance walk but left a page without `/Parent` to guess at what it inherits — the
same bug, one branch over. The class was closed only when that sibling was found
(`Sources/Toolbox/Services/PDFWriter.swift`, `inheritedResourcesEntry`, the
`depth > 0` guard).

## §2 Architectural boundaries

**§2.1 — Ghostscript runs only through `GhostscriptRunner`, and always inside the
sandbox.** No other code constructs a `Process`. Every invocation is wrapped in
`sandbox-exec` with the profile from `Sources/Toolbox/Services/SeatbeltProfile.swift`
(`SeatbeltProfile.profile`): default-deny, no network, filesystem scoped to exactly the
input, the output directory, gs's own directory and a per-run scratch dir. Input PDFs are
untrusted and Ghostscript has a CVE history (`.claude/DECISIONS.md`, 2026-07-22). A
profile change is proved by running gs under it
(`Tests/ToolboxTests/SeatbeltRunTests.swift`) — a profile that merely reads plausibly
has already failed once, for want of `(allow process-exec*)`.

**§2.2 — A sandboxed child never touches a TCC-protected path.** A seatbelt-sandboxed
child cannot inherit the app's TCC grant, so handing it a path under `~/Documents`,
`~/Downloads` or `~/Desktop` hangs it on a consent prompt it can never answer. The parent
app (which holds the grant) stages I/O through a private temp working directory and
copies results back out (`Sources/Toolbox/Compress/CompressEngine.swift`, the `work`
directory in `compress`).

**§2.3 — Module dependencies point one way.** `Models` imports no other module; everyone
may import it. `ToolQueue` is generic over its job body and knows nothing of PDFs,
Ghostscript or Vision — the view models supply the tool-specific closure. `Compress` and
`OCR` never call each other. A change that breaks any of these arrows is an architecture
change and needs the owner's agreement first.

**§2.4 — The repository builds from a fresh clone.** Every compile source and search path
in `project.yml` must resolve in a clean checkout. The one exception is
`Resources/ghostscript/` — git-ignored by design and rebuilt by
`scripts/build-ghostscript.sh` (covered by `gate: ghostscript-builds`). Dead experiments
are deleted, not left dormant: a dead `.cpp` whose search paths pointed into a
git-ignored tree built green on exactly one machine, with every gate passing, and
would have failed CI on the first push (`.claude/DECISIONS.md`, 2026-07-23, jbig2enc
removal).

## §3 The user-file safety contract

**§3.1 — Never overwrite the input, and never race for an output name.** Output names
are allocated up front, serially, before any concurrent work starts
(`Sources/Toolbox/Shared/FileNaming.swift`,
`output(for:suffix:folder:reserving:)`). A job that reaches the concurrent body with no
reserved name fails loudly (`MissingOutputReservationError`) — re-deriving a name
mid-batch reintroduces the check-then-use race the reservation exists to close.

**§3.2 — Outputs are placed by atomic rename, and a failed or cancelled job leaves
nothing behind.** Write to a hidden temp file in the destination directory (same volume,
so the rename cannot cross-device-fail), `defer` its removal, check cancellation as the
last step before `moveItem`. Both engines follow the same shape
(`Compress/CompressEngine.swift` `destTemp`/`placed`; `OCR/OCREngine.swift`
`tempURL`/`renamed`).

**§3.3 — Never deliver a larger file.** No gain means keep the original and write nothing
(`JobOutcome.noGain`). The not-smaller output must still be a *valid* PDF before it is
called no-gain — otherwise a silent gs corruption that happens to be ≥ the input
masquerades as "already optimised" (`CompressEngine.compress`, step 5).

**§3.4 — Every output is validated before it is placed, and validation is bounded in both
directions.** `Sources/Toolbox/Services/OutputValidator.swift` compares each sampled
page's ink to the *same input page* — never to an absolute floor, which falsely rejects
legitimately sparse pages — and rejects both below `minRetainedInk` and above
`maxRetainedInk`. The ceiling exists because a one-sided floor passes the worst
corruption there is: an inverted or ink-flooded page measures near 1.0 and sails through
as a success.

**§3.5 — OCR appends; it never rewrites.** The original file must be a byte-verbatim
prefix of the output (`Sources/Toolbox/OCR/OCREngine.swift`, `hasVerbatimPrefix`,
enforced in `validateOCROutput` before placement). This single invariant neutralises
whole classes of writer bugs — known and unknown — by converting silent corruption into a
visible per-file failure. Any change to `PDFWriter` that cannot keep this invariant is a
redesign, not a patch.

**§3.6 — An irreversible rebuild must prove there is nothing to destroy — per page, over
every page.** Rung 2 repaints pages as bitmaps, so everything unpainted dies with it: a
text layer (including one this app's own OCR just added), annotations, outlines.
`CompressEngine.bilevelCompress` therefore declines on any outline, any annotation, any
extractable text — checked on *every* page, never a sample, because the sampled
classifier (`PDFService.classify`) may route a document here while a page it never looked
at still carries content worth keeping. A sampled signal may route; only per-page proof
may destroy.

**§3.7 — Never `continue` past user content.** A loop over user data that skips an item
it cannot handle silently destroys that item's work while reporting success. A page index
the byte-walk cannot find fails the file (`PDFWriter.buildIncrementalSection`, the
`pageObjs[safe: pageIndex]` guard throwing `.unsupportedStructure`) so the batch
continues and the user learns the truth.

**§3.8 — A resource guard must never silently become a quality decision.** The Rung-2
render cap (`CompressEngine.maxBilevelPixels`) is a memory guard; on a large-format page
it silently became a resolution choice — an A0 sheet clamped to roughly 107 dpi, losing
hairlines, and still shipped as a success. When a cap would degrade the delivered output,
decline instead (`CompressEngine.minBilevelDPI`). A cap that degrades only internal work,
not the delivered file, is acceptable when documented as such (`OCREngine.maxRasterPixels`
reduces the recognition render, never the user's document).

## §4 Untrusted input — every PDF is hostile

**§4.1 — PDF is parsed as bytes, never as `Character`s or `String`s.** Swift collapses a
CR byte followed by LF into one grapheme cluster that equals neither `"\r"` nor `"\n"`; a
scanner built on characters fails to see the separator, misses its key, and the caller
writes a duplicate key into the document. `Sources/Toolbox/Services/PDFSyntax.swift`
is the lexical layer, byte for byte; fragments are emitted through `latin1(_:)`
(`Services/PDFWriter.swift`). Splicing a `String` into PDF bytes reintroduces the trap.

**§4.2 — "Absent" and "unparseable" are different answers, and a mutating caller must see
the difference.** A caller that reads "I could not parse this dictionary" as "the key is
not there" inserts a duplicate of a key sitting past the malformed byte — and duplicate
keys make the dictionary's meaning undefined (PDF 32000-1 §7.3.7). Any code that will
*modify* what it looked up uses `PDFSyntax.dictLookup` and treats `.unparseable` as an
error; the nil-returning `dictValue` convenience is for read-only callers. This defect
was fixed twice — the second time because the replacement type itself read a lone `>` as
end-of-dictionary — so treat the tri-state as load-bearing.

**§4.3 — Amend the format by its rules, and cite the clause at the point of use.**
Duplicate keys are forbidden, so fonts merge into an existing `/Font` rather than adding
a second key (`PDFWriter.insertFont`, §7.3.7). `/Resources` is inheritable, so a
page-level insertion must not shadow an inherited dictionary
(`PDFWriter.inheritedResourcesEntry`, Table 30). Superseding a packed object relies on
the newest cross-reference entry winning (`PDFWriter.indexObjectStreams`, §7.5.6). The
appended xref must be the same form the file already uses
(`PDFWriter.usesCrossReferenceStream`). Guessing at format semantics produced the worst
bugs this codebase has had — pages that rendered blank while the job reported success.

**§4.4 — Every allocation, recursion or walk the input can scale carries a named bound.**
New code whose memory or depth the file controls ships with a constant and a test that
exercises it; the unbounded version is a defect even if no current fixture trips it. The
existing bounds:

| Bound | Guards against | Where |
|---|---|---|
| `maxInputBytes` | one OCR job taking the machine | `Services/PDFWriter.swift` |
| `maxObjects` | an index that scales with file size, not page count | `Services/PDFWriter.swift` |
| `maxPageTreeDepth` / `maxPageTreeNodes` | stack overflow / unbounded walk from a crafted page tree | `Services/PDFWriter.swift` |
| `maxObjectStreamBytes` (whole-file budget) | decompression bombs spread across many `/ObjStm` | `Services/PDFWriter.swift` (`indexObjectStreams`) |
| `PDFFlate.inflate(limit:)` + `maxCompressedToOutputRatio` | output bombs, and copying a whole file as "compressed" input | `Services/PDFFlate.swift` |
| `maxRasterPixels` | a hostile `/MediaBox` (the spec's largest legal page is ~14 GB at 300 DPI) | `OCR/OCREngine.swift` |
| `maxBilevelPixels` | the same, on the Rung-2 render | `Compress/CompressEngine.swift` |
| `stderrLimit` + `failureMessage` | unbounded attacker-influenced text retained and shown | `Services/GhostscriptRunner.swift`, `Compress/CompressEngine.swift` |
| `wallClockTimeout` | a hung or runaway gs child | `Services/GhostscriptRunner.swift` |

**§4.5 — Untrusted arithmetic must not trap.** `Int(digits)` on a 19-digit object number
yields `Int.max`, and the first `+= 1` takes the whole process down — a crash reachable
from 27 bytes of input. Parse with overflow-reporting operations and a plausibility
ceiling (`PDFSyntax.parseInt`, `maxPlausibleInteger`); offset sums go through
`PDFWriter.addingWithinBounds`. Nothing legitimate needs values that large, so refusing
them costs nothing.

**§4.6 — Attacker-influenced text is bounded before it is kept or shown.** gs's stderr
quotes fragments of the input and a malformed PDF can provoke a warning per object; only
a bounded tail is retained (`GhostscriptRunner.drainTail`) and only the last lines reach
the UI (`CompressEngine.failureMessage`). Any new channel that carries input-derived text
to the user gets the same treatment.

## §5 Platform truths

**§5.1 — Canonicalise paths before comparing or scoping them.** The kernel resolves file
accesses to `/private/var`; a seatbelt scope entry left as `/var/…` silently fails to
match and the access is denied. Swift's `resolvingSymlinksInPath()` does *not* resolve
`/var` → `/private/var` (verified); use `URL.canonical`
(`Sources/Toolbox/Shared/CanonicalPath.swift`, C `realpath` underneath) on anything
that crosses the sandbox boundary or is compared by path.

**§5.2 — Filename identity belongs to the filesystem, not to `String` or `URL`
equality.** APFS is case- and normalisation-insensitive by default: `Report.pdf` and
`report.pdf` are the same file even though they are different `URL` values, so a
byte-exact `Set<URL>` let two batch entries reserve "distinct" names that collided at
rename. Compare by `FileNaming.reservationKey` (precomposed, lowercased). Filenames cap
at 255 UTF-8 bytes; names are truncated up front, on grapheme boundaries, with headroom
for the dedupe counter (`FileNaming.truncatedBase`).

**§5.3 — Never walk a `CGImage` buffer flat.** Rows are padded to an alignment boundary
and the padding bytes read as black: a flat index inflated every ink measurement by
roughly the padding fraction — the same order as a blank page's true ink — and blinded
the blank-page check completely. Address rows via `bytesPerRow` and sample only across
the real `width` (`Services/OutputValidator.swift`, `inkRatio`). Calibrate thresholds
only after the measurement is known-correct: thresholds tuned on a polluted metric encode
the pollution.

**§5.4 — Bytes written into a file format are locale-independent.** PDF requires `.` as
the decimal separator; a locale-aware conversion does not guarantee it. Format with an
explicitly nil locale (`Compress/BilevelPDFComposer.swift`, `number(_:)`).

**§5.5 — Behaviour never depends on hash order.** Swift seeds its hasher per process:
iterating a `Dictionary` where order decides output — or decides *which* work fits a
budget — made the same file succeed on one launch and fail on the next
(`PDFWriter.indexObjectStreams` now iterates `topLevel.keys.sorted()`). Wherever
iteration order is observable, sort first.

## §6 Concurrency and state

**§6.1 — Job bodies suspend; nothing blocks the cooperative pool.** `ToolQueue`'s
concurrency cap is only real if bodies suspend on their blocking work. Blocking calls run
on a GCD queue and are bridged with a continuation (`GhostscriptRunner.run`,
`OCREngine.renderUpright`); a body that parks a cooperative thread starves every other
job in the app.

**§6.2 — Terminal job states are absorbing.** A progress tick is an untracked `Task` and
can land after the job is `.done` — applying it resurrected finished jobs to `.running`,
where `removeCompleted()` could never reach them, stranding them forever.
`ToolQueue.setState` accepts `.running` only from `.queued` or `.running`; keep it that
way, and give any new state machine the same property.

**§6.3 — An invariant lives in the type that owns the state.** "One batch at a time" is
enforced inside `ToolQueue.run` (the `runTask` guard), not in the view models — both view
models also gate, but callers come and go, and only the owner can make the guarantee.
Re-entrancy is refused as a no-op precisely so the live batch can never be orphaned from
`cancel()`.

**§6.4 — A child process is terminated with escalation, and cancellation kills it, not
just the wait.** SIGTERM alone is not termination — a gs that installs a handler or
blocks uninterruptibly parks the waiting thread forever, leaks the queue slot and the
scratch dir. `GhostscriptRunner.terminateEscalating` follows SIGTERM with SIGKILL after a
grace period; both the watchdog and task cancellation go through it, and the child is
adopted by the cancellation handler only after launch (`RunControl.adopt`), because
`terminate()` raises on a never-launched process.

## §7 Failure honesty

**§7.1 — Exit 0 is not success; output is.** A gs that exits cleanly but produces no
output, or invalid output, is a failure — never "already optimised"
(`CompressEngine.compress`, step 4). Success is claimed only after the output exists and
validates.

**§7.2 — Error kinds tell the user the truth.** `.unsupportedStructure` ("this writer
cannot amend this file") and `.malformedPDF` ("this file is broken") are different facts
and are kept distinct even deep in the page walk (`PDFWriter.orderedPageObjects`). Every
error a job can throw is a `LocalizedError` with a specific, user-readable description —
the job list displays `errorDescription`, so an undescribed error is a UI bug.

**§7.3 — A file fails; the batch continues.** Per-file failure is the designed outcome
for anything unreadable, unsupported or invalid (`ToolQueue`'s contract: a throw fails
that one job). Failing the whole batch for one bad file, or quietly skipping the bad file
without a failed state, are both defects.

## §8 UI code

**§8.1 — A UI change is proved by driving the built app, not by a green build.** This app
once reached a green build, green tests and a working launch with a completely
non-functional UI — a "Choose Files…" button that did nothing, a window that opened
smaller than its content minimum, a mis-laid-out split view. Only Compress has an
automated end-to-end drive (`Sources/Toolbox/App/CompressSmoke.swift`, exercised by
`gate: packaged-app-compresses`); every other flow is verified by launching the app and
clicking the thing. Say what you drove in the PR.

**§8.2 — One owner per behaviour.** Two `.fileImporter` modifiers attached to the same
view conflict on macOS and neither reliably presents — which is exactly how the dead
button in §8.1 happened. File dialogs go through
`Sources/Toolbox/Shared/FilePicker.swift`; when a mechanism exists, extend it rather
than attaching a second copy of the capability elsewhere.

**§8.3 — Window behaviour is enforced on the `NSWindow`, in one place.** SwiftUI's
`.frame(minWidth:minHeight:)` constrains the *content*, not the window, and
`.defaultSize` is a hint that loses to content — a window restored too small simply
clips, and the sidebar is the casualty. All window sizing, titling and focus rules live
in `Sources/Toolbox/App/WindowConfigurator.swift` (`WindowSetup.applyMinimumSize`)
with each workaround's why documented beside it.

**§8.4 — The visual language is `DESIGN.md`'s; divergence is recorded, never silent.**
Reuse `Theme` tokens and existing components; a colour literal beside an existing token
is a defect (that exact fix: `Theme.Colors.documentBadge`). A deliberate divergence —
per-tool sidebar tints against the single-accent rule — exists only because it is
recorded in `.claude/DECISIONS.md` (2026-07-23) on the owner's instruction. Match that
bar or don't diverge.

## §9 Tests

**§9.1 — Fixtures are synthetic, generated in-process, and deterministic.** All test
content comes from `Tests/ToolboxTests/Fixtures.swift` — CoreGraphics/PDFKit
generation, a deterministic PRNG (`Fixtures.RNG`), a fresh directory per fixture
(`Fixtures.uniqueURL`). Nothing that identifies a maintainer's machine or private
material ever enters the repository — no personal paths, account names, directory names,
or descriptions of private documents. This is also a gate
(`gate: no-personal-corpus-references`, `.claude/GATES.md`); it has been violated twice
and both times cost a history rewrite. Aggregated, anonymised measurements are fine.

**§9.2 — Assert fixture invariants; never skip on a condition we control.** An
`XCTSkipIf` on an in-process fixture's size would silently retire the only test of a
memory bound the first time the fixture happened to shrink. A fixture's size is an
invariant we control, so it is asserted
(`Tests/ToolboxTests/PDFWriterTests.swift`,
`testWriterDoesNotHoldWholeCopiesOfTheInput`). Skips are for genuinely environmental
conditions only.

**§9.3 — A test proves what its name claims.** A test named itself the proof of CCITT
decoding and asserted only width and height — leaving the decoder unproven exactly where
everyone believed it proven. If the assertion is weaker than the name, weaken the name or
strengthen the assertion; if the real proof lives elsewhere, say where, in the test.

**§9.4 — Parser and boundary code gets adversarial fixtures, and resource claims get
empirical tests.** `PDFWriterTests` builds hand-armed raw PDFs (unterminated arrays,
planted keywords inside stream bodies, unreadable object streams) because the honest
fixtures never exercise the hostile paths. A documented memory bound is measured, not
asserted from reading the code (`residentFootprint` comparing peak growth against the
input size).

**§9.5 — A bug fix ships with the regression test that fails without it.** The pattern
throughout: the stale-progress fix landed with
`testLateProgressReportCannotOverwriteDoneState`
(`Tests/ToolboxTests/ToolQueueTests.swift`); the naming fixes landed with
`FileNamingTests`. An untested fix is an assertion, not a fix.

## §10 Comments, contracts and licensing

**§10.1 — Comments carry the why, and evidence beats adjectives.** The house style is a
short rule plus the measured or cited reason: threshold comments quote the measurements
that set them (`OutputValidator.contentFloor`; `PDFService.classify`'s resolution
ladder), format decisions cite the PDF clause (§4.3). A comment that restates the
signature is noise — delete it.

**§10.2 — A doc comment is a contract; code that contradicts it is a defect wherever you
find it.** A composer's doc comment promised geometry was preserved while the code
rounded the page box to whole points — a silent half-point stretch on a path that
promised none. When behaviour changes, the comment changes in the same commit; when you
find a lying comment, fixing it is not optional.

**§10.3 — Every source file carries the licence header.** All Swift sources start with
the six-line AGPL-3.0-or-later header (copyright line, SPDX identifier, licence note) —
copy it verbatim into every new file. Distribution obligations are recorded in
`.claude/DECISIONS.md` (2026-07-22, AGPL).

## §11 Language and naming

**§11.1 — Prose is British English.** Comments, documentation, commit messages, PR
descriptions: "colour", "behaviour", "organise", "analyse". User-facing strings follow
the same rule.

**§11.2 — Identifiers follow the platform, then the surrounding code.** API names are
fixed spellings (`CGColorSpace`, `-dColorImageResolution`) — never "correct" them. Our
own identifiers are predominantly British (`scanColour`, `colourDPI`, `colourSpace`);
`Theme.Colors` is an established exception. Extend whichever convention the surface you
are touching already uses — a type with `getColor()` next to `setColour()` is the rot
this rule prevents.

**§11.3 — Test names are behaviour sentences.** `testCancelLeavesRemainingQueued`,
`testSecondRunIsRefusedSoTheLiveBatchStaysCancellable` — the name states the guaranteed
behaviour, so a failure reads as a broken promise, not a broken function.

**§11.4 — There is no linter, and that is a stated fact, not an oversight.** No
formatting or lint tool is configured; per `.claude/GATES.md`, a gate whose command has
never run is not a gate. Whoever introduces a linter adds its gate in the same change —
until then, match the formatting of the file you are editing.
