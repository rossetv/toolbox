# Toolbox UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task names its model tier and track.

**Goal:** Implement the approved unified-queue redesign (spec `.claude/specs/20260730-ui-redesign.md`) — sidebar gone, one queue + two verbs in a single pass per file, per-file overrides, history, scan consent, problems as rows, self-update — at handoff fidelity.

**Architecture:** Serial foundation first (models → stores → engines → view model → design system: the whole shared layer lands before any parallel fork), then five file-disjoint parallel tracks (main screens, popovers/sheets, updater, R-net tests, DESIGN.md), then serial integration (wire → delete → docs → gates). `CompressViewModel` evolves into `QueueViewModel`; engines/stores are extended, never rewritten.

**Tech Stack:** Swift 5 / SwiftUI, macOS 14+, XCTest, xcodegen project, bundled Ghostscript (untouched).

## Global Constraints

- Spec is law: `.claude/specs/20260730-ui-redesign.md`. Design visuals/copy/motion: handoff at `$(git rev-parse --path-format=absolute --git-common-dir)/lcw/20260730-ui-redesign/handoff/` — README.md + `Toolbox Final.dc.html` + `renders/screen-*.png`. Where this plan and the spec disagree, the spec wins; report the conflict.
- Every source file: SPDX header `AGPL-3.0-or-later`, as every existing file.
- British English prose everywhere; code identifiers follow platform/API spelling.
- No new dependencies. No line-number citations in docs. Never reference the user's private test corpus — corpus-derived FIGURES go in the LCW ledger dir, never the repo.
- All numbers in UI `.monospacedDigit()`. Copy verbatim from the handoff except spec-recorded divergences (§6.3 "grew", §6.8 footer line, honest variant labels, §7 consent copy) plus the plan/spec-recorded divergences, each with an owner: the rescue meta "Couldn't be compressed — made searchable instead" (F5a), the noGain composites "Already optimised · made searchable" and "Already optimised · too faint to read" (F5a), and the compress-failure-with-OCR-off problem-row line "Couldn't be compressed" + Skip/Remove (F5a; P-A renders) — no handoff strings exist for these states.
- Never delete/skip a failing gate test. All seven `GATES.md` gates must be green before the review-team gate.
- TDD per task: failing test → run (expect FAIL) → implement → run (expect PASS) → commit. Small conventional commits, one logical change each.
- Worktrees: foundation + integration tasks run in the LCW worktree (`.claude/worktrees/ui-redesign`, branch `feat/ui-redesign`). Parallel tracks run in their own worktrees under `.claude/worktrees/` branched off `feat/ui-redesign`, merged back on completion.
- Sibling tracks: a track touches ONLY its listed files. After the fork, `Tests/ToolboxTests/Fixtures.swift`/`TestSupport.swift` are owned by track P-D; P-A/P-B/P-C add only NEW test files. (F4 first lifts the shared doubles into `TestSupport.swift` — see F4.)
- Build/test command: `xcodebuild -project Toolbox.xcodeproj -scheme Toolbox test` filtered per task with `-only-testing:ToolboxTests/<Class>`; `TEST_RUNNER_` env prefix for env vars (repo gotcha). Regenerate the project with `xcodegen` after adding files.

---

## Phase F — serial foundation (LCW worktree, tasks in order)

### Task F1: Compound outcome model (`RowOutcome`) — Opus, foundation

**Files:**
- Modify: `Sources/Toolbox/Models/JobOutcome.swift` (replace enum with compound types; `JobState` lives here and changes here — `ToolJob.swift` needs no edit)
- Modify: `Sources/Toolbox/Shared/ToolQueue.swift` (`JobResult.outcome` re-typed)
- Modify — every site returning or switching on the deleted type (grep-derived; the compiler is the completeness check): `Sources/Toolbox/Compress/CompressEngine.swift` (returns `JobOutcome` today), `Sources/Toolbox/OCR/OCREngine.swift` (same), `Sources/Toolbox/Compress/CompressViewModel.swift`, `Sources/Toolbox/App/CompressSmoke.swift`, `Sources/Toolbox/Compress/CompressView.swift`, `Sources/Toolbox/OCR/OCRViewModel.swift`, `Sources/Toolbox/OCR/OCRView.swift`
- Modify — test corpus case-reference sites (~82 across): `Tests/ToolboxTests/ToolQueueTests.swift`, `CompressEngineTests.swift`, `CompressViewModelTests.swift` (incl. its private `Compressing` stub), `CompressEngineMRCTests.swift`, `OCREngineTests.swift`, `MRCInvariantTests.swift`, `Fixtures.swift`
- Test: `Tests/ToolboxTests/RowOutcomeTests.swift` (new)

**Interfaces — Produces (later tasks rely on these exact shapes):**
```swift
// Models/JobOutcome.swift
enum RowProblem: Equatable { case locked; case missing; case unreadable
                             case compressFailed }   // meta-line vocabulary only (F5a's continuation);
                                                     // never problem-row tint/copy. Defined HERE; F4's inspection reuses the first three.
struct RetainedVariant: Equatable {
    let kind: EngineVariant          // existing .mrc/.plain/.original (VersionStore.swift)
    let bytes: Int
    var searchable: Bool
}
enum CompressOutcome: Equatable {
    case compressed(before: Int, after: Int)     // after < before, compress artefact only
    case noGain(bytes: Int)
    case skipped(problem: RowProblem)            // leg skipped by a problem while the other leg ran (spec §6.3)
}
enum OCROutcome: Equatable {
    case added(pages: Int, skipped: Int)
    case alreadySearchable
    case tooFaint                                // recognition completed, zero usable text runs on layer-less pages
                                                 // (today's ocrAdded(pages: 0) fact; no confidence signal — spec §6.3)
    case cancelled                               // batch cancelled between legs — "Compressed · not searchable — cancelled before reading" (spec §6.5)
    case failed(String)                          // user-facing message
}
struct RowOutcome: Equatable {
    var originalBytes: Int
    var finalBytes: Int                          // OWNERSHIP: the engine sets this to the COMPRESS artefact size;
                                                 // the queue's commit step (F5a) re-stats the delivered file after
                                                 // the OCR leg and OVERWRITES it. `grew` is only meaningful post-commit.
    var compress: CompressOutcome?               // nil = verb off
    var ocr: OCROutcome?                         // nil = verb off (cancelled-between-legs is .cancelled, NOT nil)
    var runnerUp: RetainedVariant?               // non-nil = second variant retained (consent/capsule trigger)
    var grew: Bool { finalBytes > originalBytes }
    // The warn/degraded classification the spec pins (rescued rows, tooFaint, cancelled-between-legs):
    var isDegraded: Bool {
        if case .skipped = compress { return true }        // rescued row (spec §6.5: warn, never "failed")
        if ocr == .tooFaint || ocr == .cancelled { return true }
        if case .failed = ocr { return true }   // recognise failure on a delivered file: degraded, never a failed row
        return false
    }   // append-failure degradation is shown via variant labels (§6.4), never row state
}
enum JobState: Equatable { case queued; case analysing; case running(Double); case done(RowOutcome); case failed(String) }
```
`JobResult` becomes `{ outcome: RowOutcome, outputURL: URL?, alternateURL: URL?, mrcReport: MRCDocumentReport? }` (same field names, `outcome` re-typed). The old `compressedHeavy` case is GONE — its information lives in `runnerUp` (kind `.mrc` when the parked loser is the hybrid, `.plain` when it is the gs output, `.original` when it is the untouched input).

**Steps:**
- [ ] 1. Write `RowOutcomeTests`: `testGrewIsDerivedFromFinalBytes`, `testRunnerUpDescriptorIndependentOfWinner` (`runnerUp: .init(kind: .mrc,…)` AND `.init(kind: .plain,…)` both construct — gs-won retention representable), `testSkippedProblemCase`, `testCancelledOCRDistinctFromNil`, `testIsDegradedPartition` (true for `.skipped`/`.tooFaint`/`.cancelled`/`.failed`; false for plain `.compressed` and `.noGain` rows), `testEquatable`. Run: expect FAIL (types missing).
- [ ] 2. Implement; delete `JobOutcome`; bridge every switch/return site with equivalent behaviour: old `.compressed(b,a)` → `RowOutcome(originalBytes: b, finalBytes: a, compress: .compressed(before: b, after: a))`; old `.compressedHeavy(b,a,r)` → same + `runnerUp: .init(kind: .mrc, bytes: r, searchable: false)`; old `.ocrAdded(p,s)` → `RowOutcome(originalBytes: n, finalBytes: n, ocr: .added(pages: p, skipped: s))`; old `.alreadySearchable`/`.noGain` likewise.
- [ ] 3. Build: expect compile FAILURES at exactly the enumerated sites; fix each mechanically; iterate to green. Then full suite: PASS (behaviour-preserving).
- [ ] 4. Commit: `refactor(models): replace JobOutcome enum with compound RowOutcome`.

### Task F1b: VersionStore four-row surface + honest labels — Opus, foundation

**Files:**
- Modify: `Sources/Toolbox/Compress/VersionStore.swift` (`RowVersions.cards`, `capsuleTitle`, new key type + mutators)
- Modify: `Sources/Toolbox/Compress/VersionsPopover.swift` — SHIM ONLY, it must keep compiling until I1b deletes it: map the new tuple at its call site (`card.key` → legacy slot: `.runnerUp`/`.previous` → their `VersionSlot`s, `.shipped` → `nil`) and FILTER `.originalReference` out entirely (the legacy popover never renders the reference row, keeping its 2–3-card geometry until death). No other change.
- Modify: `Tests/ToolboxTests/VersionStoreTests.swift` AND `Tests/ToolboxTests/CompressViewModelTests.swift` — exactly EIGHT `capsuleTitle` string assertions flip HERE (3 in `VersionStoreTests`, 5 in `CompressViewModelTests`) to the new `"N versions"` values. **`cards` arity does NOT change at F1b** — nothing sets `originalURL` until F5a, so `count == 3`-style assertions stay green here; the `row.count` re-baseline belongs to F5a. Also re-anchor the two `VersionsPopover.label(_:slot:)` doc-comment citations in these tests onto `VersionsPopoverContent` (their file dies at I1b).

**Interfaces — Produces (P-B consumes READ-ONLY; F5a is the PRODUCER of the new state):**
```swift
enum VersionCardKey: Hashable { case shipped, runnerUp, previous, originalReference }  // display identity,
                                          // distinct from VersionSlot — the parked cap stays two slots (spec §5)
// RowVersions gains:
var originalURL: URL?                      // the untouched input, for the always-present Original reference row
var searchableByCard: [VersionCardKey: Bool] = [:]   // default REQUIRED (8 existing memberwise constructions).
                                           // SEMANTICS: populated ONLY when the OCR leg ran for this row;
                                           // empty = OCR never ran → popover shows NO searchability subtitles
                                           // (design defaults stand). Never a lie in either direction.
// cards re-keys to the display identity, up to FOUR rows in popover order:
var cards: [(key: VersionCardKey, version: FileVersion)]   // shipped, runnerUp, previous, originalReference
// (originalReference appears when originalURL != nil AND no parked version already IS the original —
//  never two rows for the same file). capsuleTitle: "N versions" per handoff screen 06/07 —
//  the capsule renders ONLY when count > 1 (F7's QueueRow enforces the gate; the singular form
//  never draws, matching today's row.count > 1 gate and screen 06's capsule-less untouched rows).
// VersionStore gains the mutators F5a drives:
func setOriginalURL(_ url: URL, for id: ToolJob.ID)
func setSearchable(_ searchable: Bool, card: VersionCardKey, for id: ToolJob.ID)
```
**Stated test outcomes (loop rule — no silent drops):** `testCapsuleTitleFlipsOnSwitch` and `testCapsuleTitleReadsOriginalWhenRunnerUpIsInput` become tautologies under the static `"N versions"` label — the R15 dynamic-label family is SUPERSEDED by the handoff (authority: spec §5's radio-list supersession + handoff screens 06/07), and the honest-label invariant they proved now lives on the popover rows: **re-target** them as `testShippedCardFlipsOnSwitch` (cards' shipped entry's variant flips across a switch) and `testCardsSurfaceOriginalKindParkedVariant` (a parked `.original`-kind version surfaces with its kind intact).

**Steps:**
- [ ] 1. Extend `VersionStoreTests`: `testCardsIncludeOriginalReference`, `testNoDuplicateRowWhenParkedVariantIsOriginal` (parked `.original` kind → 3 rows, not 4), `testSearchableByCardEmptyMeansNoLabels`, `testSetSearchablePerCard`, `testConsentRetentionPlusPreviousParkStaysWithinCap` (runner-up + previous occupied → cards = 4 incl. reference, never 5); re-target the two superseded tests as stated above. FAIL → implement → PASS.
- [ ] 2. Update the eight flipped `capsuleTitle` assertions + the two doc-comment citations. Full suite: PASS.
- [ ] 3. Commit: `feat(versions): four-row card surface with honest searchability`.

### Task F2: Engine rebuild override + withhold rule + R7-reversal retention — Opus, foundation

**Files:**
- Modify: `Sources/Toolbox/Compress/CompressEngine.swift`
- Modify: `Sources/Toolbox/Compress/CompressViewModel.swift` (`Compressing` protocol + call sites gain the param, pass `nil`)
- Test: `Tests/ToolboxTests/CompressEngineTests.swift` (extend) AND `Tests/ToolboxTests/CompressEngineMRCTests.swift` (one R7 assertion superseded, the remaining seven alternate-asserting tests given stated dispositions HERE)

**Interfaces — Produces:**
```swift
func compress(_ input: URL, preset: CompressPreset, to output: URL,
              alternateOutput: URL? = nil,
              rebuildScan: Bool? = nil,          // nil = derive as today; false = never MRC; true = MRC when ELIGIBLE
              mrcReport: ((MRCDocumentReport) -> Void)? = nil,
              progress: @escaping (Double) -> Void) async throws -> JobResult
```
Rules (spec §7 Per-file settings): `rebuildScan == true` never overrides classification eligibility (`.scanColour` only, complex-page rules stand — MRC R2); `preset == .maximumQuality` forces the MRC leg off regardless (MRC D3). Withhold rule, scoped VERBATIM to spec §6.3: a would-be runner-up that is a **COMPRESS variant** ≥ input is withheld (no `alternateOutput` write, no descriptor); the **untouched-original park** (`runnerUpBytes == inputSize`, gs bloated — DECISIONS 2026-07-24's marker) is NOT a compress artefact and is RETAINED, spec §6.4. Winner ≥ input → `.noGain` (as today). `finalBytes` in the returned outcome = compress artefact size (F1's ownership note — F5a re-stats after OCR).

**Steps:**
- [ ] 1. Extend `CompressEngineTests`: `testRebuildScanFalseSkipsMRCOnScanColour`, `testRebuildScanTrueDoesNotForceIneligible` (bornDigital + `true` → plain Rung-1 — opt-in never overrides eligibility), `testRebuildScanIgnoredAtMaximumQuality`, `testRunnerUpAtOrAboveInputWithheld` (verifier override forces a bloated variant → `runnerUp == nil`). Run: FAIL.
- [ ] 1b. **R7-asymmetry reversal (spec §5 change table — an ENGINE behaviour change)**: when a valid hybrid AND a valid gs output both exist, the gate LOSER is retained to `alternateOutput` regardless of which won (today the losing hybrid is discarded). New `CompressEngineMRCTests.testHybridLostGateStillWritesRunnerUp` (hybrid lost ⇒ runner-up file written + descriptor present, kind `.mrc`). Dispositions for ALL EIGHT alternate-asserting MRC-suite tests (grep-derived, `grep -n alternate`): `testHybridLargerThanGsShipsGsOutput` — SUPERSEDED by the new test; `testHybridSmallerThanGsShipsHybridWithRunnerUp` — ADAPTS unchanged (hybrid-won retention already true); `testHybridWinsButGsCandidateNotSmallerThanInputParksOriginalAsRunnerUp` — ADAPTS UNCHANGED (the original park SURVIVES the withhold rule, see Rules); `testMRCInternalFailureShipsGsSilently` — ADAPTS unchanged (no valid hybrid exists ⇒ retention cannot fire; spec §11's hybrid-never-wins sibling); `testNeverLargerThanInputStillHolds` — ADAPTS unchanged (no-gain path: nothing valid to retain); `testScanColourOnMaximumQualityNeverAttemptsMRC`, `testScanBilevelStillRoutesToRungTwo`, `testCancelDuringRungThreeDeliversNoOutput` — ADAPT unchanged (no hybrid built on these paths). Run: FAIL → implement → PASS.
- [ ] 2. Implement (`let wantsMRC = (rebuildScan ?? true) && classification == .scanColour && preset != .maximumQuality`; withhold at the `alternateOutput` copy site; descriptor kind from which variant parked). Run: PASS. Full engine suite: PASS.
- [ ] 3. Commit: `feat(compress): per-file rebuildScan override and >=input variant withhold`.

### Task F3: OCR split + `OCRing` seam — Opus, foundation

**Files:**
- Modify: `Sources/Toolbox/OCR/OCREngine.swift`
- Test: `Tests/ToolboxTests/OCREngineTests.swift` (extend)

**Interfaces — Produces:**
```swift
struct RecognisedDocument {
    let pageText: [Int: [PositionedText]]     // Vision-normalised boxes (0…1, bottom-left) per page index
    let geometry: [Int: PageGeometry]         // ORIGINAL page geometry per index
    let pagesRecognised: Int
    let pagesSkipped: Int
}
protocol OCRing: Sendable {                    // the test seam F5a injects (mirrors `Compressing`)
    func recognise(_ input: URL, options: OCROptions,
                   progress: @escaping (Double) -> Void) async throws -> RecognisedDocument
    func append(_ recognised: RecognisedDocument, to target: URL, output: URL) throws
}
extension OCREngine: OCRing { … }
```
Geometry rule: boxes are normalised → they project onto the TARGET's own page geometry (derive per-page geometry from the target at append time; composed MRC/bilevel pages are origin-(0,0), rotation-0, MediaBox = raster size). Page-count mismatch → `OCRError.validationFailed`. `ocr(_:to:options:progress:)` remains, re-expressed as recognise+append (OCR-only path behaviour identical). Verbatim-prefix validation runs per append.

**Steps:**
- [ ] 1. Extend `OCREngineTests`: `testRecogniseThenAppendEqualsOcr`, `testAppendToComposedGeometry` (`/Rotate 90` scan → MRC-shaped composed target via the `MRCComposer` fixture path `MRCInvariantTests` uses → append → text selectable at upright position), `testAppendNeverTouchesTarget` (verbatim prefix; target unmodified), `testOriginalNeverModified`, `testAppendPageCountMismatchThrows`. Run: FAIL.
- [ ] 2. Implement split + protocol. Run: PASS. Full OCR suite: PASS. **Bail-out (spec §12): if `testAppendToComposedGeometry` cannot be made to pass, take the spec's recorded fallback — append only to Rung-1-shaped variants, composed variants labelled "not searchable" — and REPORT to the orchestrator; never a silent narrowing.**
- [ ] 3. Commit: `feat(ocr): recognise/append split behind OCRing seam`.

### Task F4: QueueViewModel part 1 — rename, doubles, verbs, inspection, reservation — Opus, foundation

**Files:**
- Rename: `Sources/Toolbox/Compress/CompressViewModel.swift` → `Sources/Toolbox/Queue/QueueViewModel.swift` (git mv; class renamed)
- Create: `Sources/Toolbox/Queue/RowInspection.swift`
- Modify: `Sources/Toolbox/Shared/ToolQueue.swift` (admission during run), `Sources/Toolbox/App/RootView.swift` + `Compress/CompressView.swift` (mechanical rename only)
- Modify: `Tests/ToolboxTests/TestSupport.swift` (doubles lifted here), `Tests/ToolboxTests/ToolQueueTests.swift` + `Tests/ToolboxTests/CompressEngineTests.swift` (their private `Gate` duplicates die; the add-while-running flips land HERE), rename `CompressViewModelTests.swift` → `QueueViewModelTests.swift`
- Test: `Tests/ToolboxTests/QueueAdmissionTests.swift` (new)

**Interfaces — Produces:**
```swift
// TestSupport.swift gains INTERNAL (not private) shared doubles:
final class StubCompressEngine: Compressing { /* lifted from QueueViewModelTests' private StubEngine;
    arity re-derived for width > 1: independent per-job continuations, concurrent in-flight support */ }
final class StubOCREngine: OCRing { /* gated recognise/append with per-call continuations, width > 1 */ }
actor Gate { /* single definition; the three private duplicates in CompressEngineTests/QueueViewModelTests/ToolQueueTests delete in favour of this */ }

struct RowOverride: Equatable { var preset: CompressPreset?; var rebuildScan: Bool?; var ocr: Bool? }
struct RowInspection: Equatable {
    var pageCount: Int?; var hasTextLayer: Bool?; var contentType: PDFContentType?; var problem: RowProblem?
    var metaLine: String   // copy per handoff Ready screen
}
// QueueViewModel adds:
init(engine: (any Compressing)?, ocrEngine: (any OCRing)?, estimator: …, store: …)   // OCR seam injected
@Published var compressOn: Bool = true
@Published var ocrOn: Bool = false
@Published var ocrOptions = OCROptions()
@Published private(set) var overrides: [ToolJob.ID: RowOverride] = [:]
@Published private(set) var inspections: [ToolJob.ID: RowInspection] = [:]
func setOverride(_ o: RowOverride?, for id: ToolJob.ID)
func effectivePreset(for id: ToolJob.ID) -> CompressPreset
func effectiveVerbs(for id: ToolJob.ID) -> (compress: Bool, ocr: Bool)   // floor: never both false (spec §6.1)
func rebind(_ id: ToolJob.ID, to url: URL)
var canStart: Bool
// The reservation ledger's ONLY mid-run mutation surface (F5a's contingency is its one sanctioned caller):
func reserveDelivery(suffix: String, for id: ToolJob.ID) -> URL
func releaseDelivery(for id: ToolJob.ID)
func clearFinished()   // existing method; behaviour extended to release the cleared rows' reservations
```
Reservation moves to `add(_:)` (delivered suffix per spec §6.5: compress-inclusive run → `-compressed.pdf`, OCR-only → `-ocr.pdf`; suffix re-reserved when the verb set changes while idle); release+re-reserve on destination/verb/override/rebind changes while idle; settings lock per run; mid-run adds reserve against locked settings. `ToolQueue.add` accepts during a run (launch loop re-polls queued jobs until drained); the `run` RE-ENTRANCY guard is untouched — a second `run` stays refused, `testSecondRunIsRefusedSoTheLiveBatchStaysCancellable` stays green. The two tests asserting the OLD add guard flip IN THIS TASK (not P-D's): `ToolQueueTests.testAddWhileRunningIsRefused` and `QueueViewModelTests.testAddIsIgnoredWhileABatchIsRunning` are each SUPERSEDED by `testAddDuringRunJoinsBatch`. `clearFinished()` releases the cleared rows' reservations (declared in Produces). Inspection on add off-main (`OpenGuard.inspect` + `pageHasText` sample + estimator analysis); failures → `problem`, excluded from `canStart`. `RowProblem.compressFailed` is UNREACHABLE in inspection — the switch ignores it (no tint, no copy; it exists only for F5a's meta line).

**Steps:**
- [ ] 1. `git mv` + mechanical rename repo-wide. Full suite PASS. Commit: `refactor(queue): rename CompressViewModel to QueueViewModel`.
- [ ] 2. Lift doubles into `TestSupport.swift` (internal), re-derive width>1 arity, delete the three private duplicates; suite PASS. Commit: `test(support): shared width-aware engine doubles`.
- [ ] 3. Write `QueueAdmissionTests`: `testAddDuringRunJoinsBatch`, `testAddDuringRunReservesAgainstLockedSettings`, `testReservationReleasedOnRemove`, `testClearReleasesReservationsAndReAddDoesNotSuffix`, `testFolderChangeReReservesWhileIdle`, `testVerbSetChangeFlipsSuffix` (compress-on → `-compressed.pdf`; toggle to OCR-only while idle → re-reserved `-ocr.pdf`), `testPerRowOCROverrideFlipsSuffix`, `testRebuildScanFlipAddsAndRemovesAlternateReservation`, `testRebindReReservesWhileIdle`, `testOverrideVerbFloorBlocksLastVerbOff`, `testZeroVerbsDisablesStart`, `testProblemRowExcludedFromCanStart`. Run: FAIL.
- [ ] 4. Implement part-1 surface. Run: PASS. Full suite: PASS.
- [ ] 5. Commit: `feat(queue): verbs, overrides, add-time inspection and reservation`.

### Task F5a: Single-pass job body — Opus, foundation

**Files:** Modify `Sources/Toolbox/Queue/QueueViewModel.swift` (`RowProblem.compressFailed` is F1's definition — F5a only PRODUCES it). Tests: `Tests/ToolboxTests/QueuePassTests.swift` (new) + `Tests/ToolboxTests/QueueViewModelTests.swift` (re-baseline: `row.count` 2 → 3 where the Original reference row now appears — `originalURL` is populated from this task on; `VersionStoreTests`' own `count == 3` stays 3, that test constructs `RowVersions` directly and never sets `originalURL`).

Job body per file (spec §6.2/§6.4/§6.5/§6.8): compress leg (when effective-on, per-row `preset`/`rebuildScan`) → cancellation check → OCR leg (when effective-on; width-2 semaphore; `recognise` from ORIGINAL, `append` to delivered file via temp + `replaceItemAt`, and to a retained runner-up variant file; `.original`-kind runner-up NEVER appended; append failure → `searchable = false`, never a job failure) → cancellation check → re-stat `finalBytes`, commit. Cancel between legs → `.ocr = .cancelled`, kept-and-banked.

**Recognise-failure on the compress-delivered path** (spec §7's degraded family): a `.failed` OCR outcome after a successful compress delivery NEVER fails the job — the compressed file is kept and banked, `ocr = .failed(msg)`, row classified degraded; test `testCompressDeliveredOCRRecogniseFailureIsDegradedNotFailed`. **OCR-off compress failure**: OCR effective-off + `ghostscriptFailed`/`validationFailed` → the throw propagates → `JobState.failed("Couldn't be compressed")` — `RowProblem.compressFailed` is NOT the carrier there (it stays meta-line-only for the rescue); test `testCompressFailureWithOCROffFailsRow`.
**Producer duties pinned here**: the commit step populates F1b's new state — `setOriginalURL(job.url)`, then `setSearchable` per card from the append results: `.shipped`/`.runnerUp`/`.previous` = did that file's append succeed; `.originalReference` (and any `.original`-KIND parked version) = `ocr == .alreadySearchable` — **[SPEC AMENDED 2026-07-30, panel verdict + DECISIONS entry: §6.4 is outcome-keyed — the Original row is labelled searchable iff the OCR leg returned `.alreadySearchable`; "searchable" = extractable text layer on every page, keyed to the recorded outcome, never a fresh probe; the shipped-unsearchable/Original-searchable corollary is legal and tested (`testShippedUnsearchableOriginalSearchableCorollary`)]**; no OCR leg ran → no `setSearchable` calls at all (empty map = no labels). **Selecting the Original reference row** (design screen 07 makes it a radio target): `func useCard(_ key: VersionCardKey, for job: ToolJob) async` maps `.runnerUp`/`.previous` onto the existing `useVersion`; `.originalReference` parks the shipped file and installs a COPY of the original at the delivered path (the original in its own folder is NEVER touched); no re-append (the copy is byte-identical to the never-modified input). **Failure disposition** (recorded lesson — never assume a throw destroyed a file): copy fails → restore the just-parked shipped file to the delivered path; restore fails → the row states where the file is (parked path named), nothing deleted. Tests `testUseOriginalReferenceCopiesNeverMoves` + `testUseOriginalReferenceCopyFailureRestoresShipped`. **Rescue-leg no-delivery dispositions (spec §6.5)**: `.alreadySearchable`/`.tooFaint` on the rescue leg release the `-ocr` reservation, deliver nothing, and take the OCR-only pipeline's disposition (warn/degraded, copy naming the compress failure) — tests `testRescueAlreadySearchableShipsNothing`, `testRescueTooFaintShipsNothing`. Sum exclusions are asserted where the sums exist: `testOCROnlyAndRescuedRowsExcludedFromSavedSoFar` (F5c) and `testOCROnlyAndRescuedRowsExcludedFromSavedBytes` (F6) — F5a itself asserts only the row-level classification.
**`CompressOutcome.skipped(problem:)` producer**: a compress-specific failure (`CompressError.ghostscriptFailed`/`.validationFailed`) while OCR is effective-on does NOT fail the job — the body reserves a contingency `-ocr` name through F4's `reserveDelivery(suffix:for:)` (the SAME main-actor ledger that serves mid-run adds — no filesystem race; the `-compressed` reservation is released via `releaseDelivery(for:)`, so one name per job ships). **[SPEC AMENDED 2026-07-30, panel verdict + DECISIONS entry: §6.5 gains the compress-failure OCR rescue with five binding pins — rescued row classified warn/degraded, NEVER "failed" (Problems footer stays true); counts as OCR-only in every savings sum (grey "no change", never toward "N MB saved"); rescue-leg OCR failure releases BOTH reservations and fails to a problem row (worst case = no-rescue); encrypted/corrupt fail the whole job; compress failure with OCR OFF fails the row with a recorded copy-divergence problem line. Tests add `testRescuedRowClassifiedWarnNotFailed`, `testRescuedRowCountsAsOCROnlyInSums`, `testRescueOCRFailureReleasesBothReservations`]**. The SAME mid-run reservation switch serves the sibling carve (spec §6.5 amended, pinned in full): a `noGain` compress verdict with OCR effective-on and outcome `.added` delivers original-plus-layer under `-ocr.pdf`; the row is an OCR-only delivery (grey sizes, excluded from every savings sum, counts via `searchableCount`, meta "Already optimised · made searchable"); `.alreadySearchable` → nothing ships, both reservations released, unchanged row; `.tooFaint` → nothing ships, degraded warn row; `.failed` → both reservations released, job fails, original untouched. Tests `testNoGainWithOCRDeliversOcrName`, `testNoGainWithOCRExcludedFromSavings`, `testNoGainAlreadySearchableShipsNothing`, `testNoGainOCRFailureReleasesBothReservations`. It continues the OCR leg against the ORIGINAL and commits `compress = .skipped(problem: .compressFailed)` (defined in F1; its ONLY consumer is the row meta line — never problem-row tint/copy) with meta "Couldn't be compressed — made searchable instead" (recorded copy divergence). `CompressError.encrypted`/`.corrupt` fail the whole job (OCR would fail identically) → problem row. **Any other throw (`.sameInputOutput`, `CancellationError`, non-`CompressError`) propagates out of the body unchanged — never the OCR continuation.**

- [ ] 1. Write `QueuePassTests`: `testCompressThenOCRSingleRow`, `testOCRAppliedToRunnerUpVariant` (both files carry layer, assert `pageHasText` each), `testOriginalVariantNeverAppended` (file untouched, `searchable == false`), `testSearchableByCardReflectsAppendOutcomes` (incl. empty-map when OCR off), `testUseOriginalReferenceCopiesNeverMoves`, `testCompressFailureContinuesOCRLeg` (stub throws `ghostscriptFailed`; OCR on → contingency `-ocr` reservation through the ledger, output delivered, `compress == .skipped(problem: .compressFailed)`, `-compressed` reservation released), `testEncryptedFailsWholeJob`, `testCancelBetweenLegsBanksCompressed` (asserts `.ocr == .cancelled` + file kept), `testCancelStopsQueue` (successor to `OCRViewModelTests.testCancelStopsTheViewModelsQueue` — no further job starts after cancel), `testOCROnlyRowNoSizeLie`, `testOCRSemaphoreWidthTwo` (4 jobs, gated `StubOCREngine` → ≤2 concurrent in OCR leg), `testFinalBytesRestatedAfterAppend`, `testCancelBetweenEngineReturnAndCommit`, plus every prose-named test above folded into THIS manifest: `testUseOriginalReferenceCopyFailureRestoresShipped`, `testShippedUnsearchableOriginalSearchableCorollary`, `testRescuedRowClassifiedWarnNotFailed` (asserts `isDegraded` true AND state ≠ `.failed`), `testRescueAlreadySearchableShipsNothing`, `testRescueTooFaintShipsNothing`, `testRescueOCRFailureReleasesBothReservations`, `testNoGainWithOCRDeliversOcrName`, `testNoGainAlreadySearchableShipsNothing`, `testNoGainOCRFailureReleasesBothReservations` (the two SUM-exclusion tests live in F5c/F6 where the sums exist). Run: FAIL.
- [ ] 2. Implement (leg-boundary checks per concurrency lessons: guard before first await, re-check between engine return and commit). Run: PASS. Full suite: PASS.
- [ ] 3. Commit: `feat(queue): single compress+OCR pass per file`.

### Task F5b: Consent queue — Opus, foundation

**Files:** Modify `Sources/Toolbox/Queue/QueueViewModel.swift`. Test: extend `QueuePassTests.swift`.

```swift
@Published private(set) var pendingConsents: [ToolJob.ID] = []      // FIFO, surfaced one at a time, mid-run (spec §7)
@Published var rebuildWithoutAsking: Bool                            // UserDefaults-backed
func resolveConsent(_ id: ToolJob.ID, keepRebuilt: Bool)             // instant switch via RunnerUpStore.switchVersions when needed
```
Trigger = completed job with `runnerUp != nil` on the rebuild path. Pref on → no sheet, keep REBUILT when it exists+validates (spec §7's toggle promise). Consent-retained loser occupies the runner-up slot (cap ruling — F1b's test covers the collision with a later previous-park).

- [ ] 1. Tests: `testConsentQueuedFIFOAndResolved`, `testConsentAppearsMidRun` (first consent surfaces while a later job still runs), `testConsentFiresRegardlessOfGateWinner` (descriptor-present on a gs-won row ⇒ sheet fires — the R7-reversal's VM half), `testRebuildWithoutAskingSkipsConsentAndKeepsRebuilt` (assert ALSO that the versions capsule/runner-up remains available — the undo leg), `testConsentKeepPhotographsSwapsInstantly`. FAIL → implement → PASS.
- [ ] 2. Commit: `feat(queue): scan-rebuild consent queue`.

### Task F5c: Batch progress + ETA — Sonnet, foundation

**Files:** Create `Sources/Toolbox/Queue/BatchProgress.swift`; modify `QueueViewModel.swift`. Test: `Tests/ToolboxTests/BatchProgressTests.swift` (new).

```swift
struct BatchProgress: Equatable { let fraction: Double; let etaSeconds: Int?; let savedSoFarBytes: Int }
// QueueViewModel: @Published private(set) var batchProgress: BatchProgress?
func legLabel(for id: ToolJob.ID) -> String?   // "Compressing…" / "Rebuilding scan…" / "Reading page N of M"
func measuredPageRate(for id: ToolJob.ID) -> Double?   // per-page seconds from the row's completed run (P-B duration lines)
```
ETA: smoothed completed-fraction rate, nil until batch fraction ≥ 0.1; monotonic display.

- [ ] 1. Tests: aggregation, nil-before-10% (`testETANilBeforeTenPercent`), monotonicity, per-leg labels, `measuredPageRate` recorded post-run, `testOCROnlyAndRescuedRowsExcludedFromSavedSoFar` (spec §6.5: `savedSoFarBytes` sums COMPRESSED rows only — OCR-only, rescued and noGain+OCR rows contribute zero), plus the three `BatchProgressTextTests` assertions re-homed here with stated outcomes in a file comment atop `BatchProgressTests` (counts-current-file → aggregation tests; clamps-at-finish → `testReadingPageLabelClampsAtPageCount` — the same off-by-one shape the old test documented, now on `legLabel`'s "Reading page N of M"; uses-given-verb → per-leg label tests). FAIL → implement → PASS. Commit: `feat(queue): batch progress and measured ETA`.

### Task F5d: Estimator MRC calibration — Opus, foundation

**Files:** Modify `Sources/Toolbox/Compress/CompressEstimator.swift`. Test: extend `Tests/ToolboxTests/EstimatorTests.swift`.

Two-part measurement (spec §6.7), in order:
- [ ] 1. Synthetic measurement: run the actual MRC pipeline on the repo's scanColour fixtures; record achieved reductions in the task log.
- [ ] 2. Corpus measurement: run the same on the private corpus; record FIGURES ONLY in `$(git rev-parse --path-format=absolute --git-common-dir)/lcw/20260730-ui-redesign/calibration.md` — never in the repo (`no-personal-corpus-references` gate).
- [ ] 3. Set `baseReduction[.scanColour]` from the measurements (untempered constants chosen so the TEMPERED prediction `base * (0.3 + 0.7 * payloadRatio)` lands within ±15% of measured on both sets; expected neighbourhood `.balanced` ≈ 0.75, `.smallestSize` ≈ 0.80 — the measurements decide). **`.maximumQuality` stays untouched at 0.12 — MRC never runs there (MRC D3), so an MRC-derived constant would predict what the engine cannot deliver.** Fallback if ±15% is unreachable with one constant: widen to ±25%, keep "about" phrasing, and record the achieved tolerance in the plan (edit this step's line with the final constants + tolerance).
- [ ] 4. `EstimatorTests`: `testScanColourPredictionMatchesMRCPipelineOnFixture` (tolerance per step 3), existing fallback tests still green. Commit: `feat(estimate): calibrate scanColour to the MRC path`. **Final constants recorded here post-measurement: ___ (implementer fills in).**

### Task F6: HistoryStore — Sonnet, foundation

**Files:** Create `Sources/Toolbox/Queue/HistoryStore.swift`; modify `Sources/Toolbox/Queue/QueueViewModel.swift` (batch-end recording). Tests: `Tests/ToolboxTests/HistoryStoreTests.swift` (new) + extend `QueuePassTests.swift`.

Interfaces as specified: `HistoryBatch` (id/date/folderName/folderURL/fileCount/presetTitle?/compressOn/ocrOn/savedBytes/searchableCount/partial/problem/cancelled), `HistoryStore` (`retentionLimit = 200` — covers months of heavy use at trivial size, bounds growth; `batches` newest-first; `lifetimeSavedBytes`; `record`; `clearList()` empties batches ONLY, lifetime survives — spec §6.9; `groupedByDay`). Disk envelope `{"version":1,…}`; foreign version → empty start, never overwrite until next record. VM records at batch end incl. cancel-with-banked; cancel-with-nothing-banked records nothing.

- [ ] 1. `HistoryStoreTests`: round-trip, `testClearListPreservesLifetime`, trim at 200, day grouping, corrupt/foreign-version → empty. FAIL → implement → PASS.
- [ ] 2. `QueuePassTests`: `testBatchEndRecordsHistory`, `testCancelledBatchWithBankedFileRecordsEntry`, `testCancelledEmptyBatchRecordsNothing`, `testOCROnlyAndRescuedRowsExcludedFromSavedBytes` (history `savedBytes` sums compressed rows only; rescued/noGain+OCR count via `searchableCount`). FAIL → wire → PASS.
- [ ] 3. Commit: `feat(history): recent-batches store with lifetime savings`.

### Task F7: Design system — tokens + full component inventory — Sonnet, foundation

**Files:** Modify `Sources/Toolbox/DesignSystem/Theme.swift`, `Components.swift` (restyle kept: `PrimaryButton`, `LinkButton`, `StatPill`, `PDFThumbnail`); create `Sources/Toolbox/DesignSystem/QueueComponents.swift`. Test: `Tests/ToolboxTests/ThemeTests.swift` (new).

Tokens (handoff README table, light+dark): `Theme.Colors` bg/surface/text/text2/text3/accent/link/success/warn/danger/stroke/sep/hairline/fill/track; `Theme.Radius` row 10, control 8, popover 12, sheet 14, capsule 980; `Theme.Motion` standard spring(0.35, 0.85), hover .15, press .12, popover .3, sheet .38, banner .45, checkPop .45; `Theme.Typography` adds windowHeadline/sheetTitle/rowName/bodyStrong/body13/meta/caption/sectionLabel.

`QueueComponents.swift` — the COMPLETE control inventory for all 14 screens (P-A/P-B create no components; a missing one is a stop-and-report, never an improvisation):
```swift
struct VerbChip: View { let title: String; let suffix: String?; let isOn: Bool; let icon: Image
                        let toggle: () -> Void; let openOptions: (() -> Void)? }   // two actions, two VoiceOver labels
struct StatusIndicator: View { enum Kind { case finished; case active(Double); case queued; case unchanged; case warn }; let kind: Kind }   // .warn renders degraded rows (spec §6.5: rescued, tooFaint) — outline-warn glyph, warn tint
struct CapsuleProgressBar: View { let fraction: Double }
struct OptionCard: View { let title: String; let value: String; let caption: String
                          let captionTone: Tone; let isSelected: Bool; let action: () -> Void
                          enum Tone { case success, muted, plain } }
struct QueueRow: View { /* thumbnail, name, meta(+accent), 70pt trailing sizes column, hover+focus gear,
                           status slot, capsule; onOpen/onGear/onCapsule/onRemove; keyboard-focusable */ }
struct BatchCard: View { let icon: StatusIndicator.Kind; let title: String; let subtitle: String; let action: () -> Void }
struct SecondaryButton: View { let title: String; var icon: Image? = nil; let action: () -> Void }
                        // handoff: shadow 0 .5px 1.5px rgba(0,0,0,.18) + inset ring; dark #3a3a3c
struct SegmentedRow: View { let options: [String]; @Binding var selection: Int }        // 04b Fast/Accurate, 04c quality
struct DropdownRow: View { let label: String; let options: [String]; @Binding var selection: String }  // 04b language
struct ToggleRow: View { let title: String; let stateLine: String; @Binding var isOn: Bool }            // 04c
struct RadioRow: View { let title: String; let subtitle: String; let isSelected: Bool
                        var subtitleTone: Tone = .plain; let action: () -> Void; enum Tone { case plain, accent } } // 07
struct CheckRow: View { let title: String; @Binding var isChecked: Bool }               // 08 "Choose which files…"
struct PopoverChrome<Content: View>: View; struct SheetChrome<Content: View>: View; struct UpdateBannerChrome<Content: View>: View
```
Every interactive component: `.clearsClickFocus()` (standing invariant) + hover states + Reduce Motion variants + VoiceOver labels for compound/stateful controls (spec §9).

- [ ] 1. `ThemeTests`: exact token values/radii/durations. FAIL → implement → PASS. Commit: `feat(design): handoff token set`.
- [ ] 2. Build `QueueComponents` with a preview per component covering every state. Suite PASS. Commit: `feat(design): queue component library`.
- [ ] 3. Restyle kept components (no API change). Suite PASS. Commit: `style(design): retoken kept components`.

**FORK POINT — after F7, tracks P-A…P-E run in parallel worktrees.** Every track prompt carries: touch ONLY your listed files; a needed change outside them is a stop-and-report to the orchestrator; never stash/revert/clean sibling work.

---

## Phase P — parallel tracks

### Task P-A: Main-window screens — Sonnet, track A (worktree `…/ui-redesign-a`)

**Files (create only):** `Sources/Toolbox/Queue/QueueView.swift`, `EmptyStateView.swift`, `DragOverlayView.swift`, `QueueHeaderView.swift`, `QueueRowsView.swift`, `QueueFooterView.swift`. Test: `Tests/ToolboxTests/QueueViewStateTests.swift` (new). Footer sums render VM aggregates ONLY (`BatchProgress.savedSoFarBytes` etc.) — the OCR-only/rescued exclusion is F5c's rule; the footer never recomputes sums. Degraded rows render `StatusIndicator.Kind.warn`. Label tests include one ABSENCE assertion: a compress-only row has no searchability subtitle in either direction.

**Interfaces — Consumes:** `QueueViewModel` (F4/F5 surface), `HistoryStore` (F6), `QueueComponents` (F7), `FilePicker`, `RowVersions` read-only. **Produces — the FROZEN injection seam (I1 plugs P-B's views into exactly these EIGHT slots; no other cross-track reference exists):**
```swift
struct QueueView: View {
    init(model: QueueViewModel, history: HistoryStore,
         quality: @escaping () -> AnyView,                 // Quality popover content
         ocrOptions: @escaping () -> AnyView,              // OCR popover content
         perFile: @escaping (ToolJob.ID) -> AnyView,       // Per-file settings popover content
         versions: @escaping (ToolJob.ID) -> AnyView,      // Versions popover content (capsule anchor)
         changeQuality: @escaping () -> AnyView,           // Change-quality sheet content
         scanConsent: @escaping (ToolJob.ID) -> AnyView,   // Scan-choice consent sheet content
         recentBatches: @escaping () -> AnyView,           // Recent-batches sheet content
         about: @escaping () -> AnyView)                   // About sheet content (⋯ menu + app menu)
}
```
P-A owns the `⋯` button AND its menu (Recent batches… → `recentBatches` slot; Where files are saved… → `FilePicker.chooseFolder()` directly, no view; About Toolbox → `about` slot). EIGHT slots total — the freeze claim covers all of them; no other cross-track reference exists.
Visual truth: handoff README §Screens + renders 01/02/03/05/06/10 + HTML sections. Divergences per spec (multi-active rows; truthful footer copy; "grew" meta; Skip/Remove/Find-it only).

- [ ] 1. `QueueViewStateTests`: state selection (empty/ready/working/finished derivation), drop accepted in every state, Return on focused row invokes onOpen. FAIL → implement → PASS.
- [ ] 2. Build each view against renders (entrance animations; Reduce Motion variants; VoiceOver labels on status column). One commit per view file.
- [ ] 3. A11y step: VoiceOver label audit over chips/status/gear/capsule (assert `accessibilityLabel` presence in state tests where the API allows), Reduce Motion paths compile-checked via previews. Commit.

### Task P-B: Popovers + sheets — Sonnet, track B (worktree `…-b`)

**Files:** Create `Sources/Toolbox/Queue/QualityPopover.swift`, `OCRPopover.swift`, `PerFileSettingsPopover.swift`, `VersionsPopoverContent.swift` (NEW file — the old `Compress/VersionsPopover.swift` is left COMPLETELY untouched; its live consumer `CompressView` survives until I1b, so an in-place rewrite would break this track's own build), `ChangeQualitySheet.swift`, `ScanConsentSheet.swift`, `RecentBatchesSheet.swift`; modify `Sources/Toolbox/App/AboutView.swift` (redesign per screen 11 — init STAYS no-arg `AboutView()` (SidebarView still calls it until I1b); **PRESERVE the three `.focusEffectDisabled()` modifiers**, the About-sheet net of the stray-focus-ring invariant). Test: `Tests/ToolboxTests/PopoverLogicTests.swift` (new).

**Interfaces — Consumes (read-only):** `QueueViewModel` surface, `RowVersions.cards`/`searchableByCard` (F1b), `HistoryStore.groupedByDay`, `measuredPageRate` (F5c), `QueueComponents` (complete inventory — a missing component is a stop-and-report). **Produces (exact inits P-A's seam receives):** `QualityPopover(model:)`, `OCRPopover(model:)`, `PerFileSettingsPopover(model:jobID:)`, `VersionsPopoverContent(model:jobID:)`, `ChangeQualitySheet(model:)`, `ScanConsentSheet(model:jobID:)`, `RecentBatchesSheet(history:)`, `AboutView()` (no-arg, frozen).

- [ ] 1. `PopoverLogicTests`: quality totals per preset from analyses; per-file estimate reflects overrides; change-quality deltas from current rows; duration lines only when `measuredPageRate` non-nil; consent honest copy for `.original` kind; `testCompareVersionsPairSelection` (see step 2). FAIL → implement → PASS.
- [ ] 2. **Compare versions…** (handoff screen 07 footer, spec §7 — the ONLY comparison affordance; D8's in-app comparator stays rejected): full-width secondary button; PAIR = the in-use version + the currently highlighted row (highlight on the in-use row → in-use + first parked); opens both via `NSWorkspace.shared.open` (the existing open pattern — Preview handles PDFs); DISABLED when the row has only one file. Logic test `testCompareVersionsPairSelection` covers all three highlight cases + the disabled state. NOTE: the redesign has NO Quick-Look surface — `quickLookURL`/`frozenQuickLookItems`/`freezeQuickLookItems`/`.quickLookPreview` all live in `CompressView.swift` and retire with it at I1b; none is needed here.
- [ ] 3. One commit per view. A11y: labels for radio/toggle/check rows; Reduce Motion on sheet/popover motion.

### Task P-C: Self-updater — Opus, track C (worktree `…-c`)

**Files:** Create `Sources/Toolbox/App/SelfUpdater.swift`, `Sources/Toolbox/App/UpdateBanner.swift`. Modify `Sources/Toolbox/App/UpdateChecker.swift`. Test: `Tests/ToolboxTests/SelfUpdaterTests.swift` (new, fixture-served).

**Interfaces — Produces:**
```swift
// UpdateChecker.Release gains: let dmgURL: URL?
//   parseRelease pins dmgURL to scheme https + host github.com EXACTLY (install.sh's pin; no other host).
//   nil if the release has no .dmg asset — the release still PARSES (banner shows, button degrades to the
//   release page); UpdateCheckerTests' existing assets:[] fixtures therefore need NO edit.
@MainActor final class SelfUpdater: NSObject, ObservableObject, URLSessionTaskDelegate {
    enum Phase: Equatable { case idle; case blockedByRun; case downloading(Double); case verifying; case installing
                            case degradedToReleasePage(reason: String); case failed(message: String, asidePath: String?)
                            case relaunching }
    @Published private(set) var phase: Phase = .idle
    init(release: UpdateChecker.Release,
         isBusy: @escaping () -> Bool,                    // I1 wires to { model.isRunning }
         sessionConfiguration: URLSessionConfiguration = .ephemeral,   // updater BUILDS its session with self as delegate
         bundleURL: URL = Bundle.main.bundleURL)
    static func installDestination(for bundleURL: URL) -> URL?   // writable …/Applications parent, else nil
    func update() async                                   // isBusy() → .blockedByRun, no side effects
    // Redirect policy (install.sh posture): follow hops; enforce https per hop via the ASYNC delegate
    // variant, declared NONISOLATED (the completion-handler form cannot await; a @MainActor-isolated
    // implementation cannot satisfy the nonisolated requirement and would race a security check):
    //   nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
    //       willPerformHTTPRedirection response: HTTPURLResponse,
    //       newRequest request: URLRequest) async -> URLRequest?
    // — non-https redirect → task.cancel(); return nil (nil = don't follow);
    //   await MainActor.run { phase = .failed(…) }.
    // Host-check the INITIAL URL only (parseRelease's pin). No redirect-host allow-list: probed 2026-07-30,
    // GitHub currently redirects to release-assets.githubusercontent.com and has changed this host before —
    // any list would be perishable.
}
```
Flow per spec §6.10: sha256 vs `<dmgURL>.sha256` → mount (plist-parsed) → payload+version check → strip quarantine on STAGED copy pre-swap iff `spctl` rejects (strip failure → abort pre-swap) → aside-swap (restore on failure; restore-failure → aside preserved + path in `.failed`) → detach best-effort → detached `/bin/sh` relaunch helper → terminate.

- [ ] 1. `SelfUpdaterTests` (fixture HTTP server + `hdiutil create` DMGs): checksum mismatch → `.failed`, no swap; mount failure; `testPayloadMissingAppFails`; wrong payload version; `testQuarantineStripFailureAbortsPreSwap` (strip fails on the staged copy → abort, current install untouched); `installDestination` nil → degrade; swap failure legs → working install remains, aside named on restore-failure; success path; `testUpdateRefusedWhileBusy` (`isBusy` true → `.blockedByRun`, filesystem untouched); `testNonHTTPSRedirectCancelled` (fixture redirect to `http://` → `.failed`); `testHTTPSRedirectFollowed` (fixture serves the DMG via a 302 to a second local https port — download succeeds; the redirected host is deliberately unconstrained, spec §6.10). Never live GitHub. FAIL → implement → PASS.
- [ ] 2. **Banner dismissal (spec §7/§10)**: × dismiss persists PER VERSION. Produces (added to the block above): `struct UpdateBanner: View { init(release: UpdateChecker.Release, updater: SelfUpdater) }` — the dismissal state lives INSIDE the banner as `@AppStorage("bannerDismissed") private var dismissedVersion: String = ""`; the banner renders nothing when `dismissedVersion == release.version`, re-shows for a newer version. I1a mounts it (its step names the mount). Tests `testBannerDismissalPersistsPerVersion`, `testNewerVersionReShowsBanner` (logic-level on the dismissal predicate).
- [ ] 3. Commits: `feat(update): release asset parsing`, `feat(update): self-updater state machine`, `feat(update): banner view` (banner shows `blockedByRun` as disabled button + caption "after the current batch finishes").

### Task P-D: R-net test re-derivation — Opus, track D (worktree `…-d`)

**Files:** Modify `Tests/ToolboxTests/QueueViewModelTests.swift`, `Fixtures.swift`, `TestSupport.swift`, `ToolQueueTests.swift`, `VersionStoreTests.swift`, `RunnerUpStoreTests.swift` as consequences demand. No `Sources/` edits — a needed VM change is a stop-and-report.

Protocol (spec §11, widened): enumerate all **62** existing `QueueViewModelTests` funcs + the untagged early block, AND every test in ANY suite whose asserted behaviour this spec reverses — located by grepping the MECHANISM'S SYMBOLS (`runTask == nil`, `isRunning`, `alternateOutput`), never rule tags alone; each gets **adapt** / **superseded-by(name)** / **new sibling**. Already-owned flips stay with their owners (F2 owns the MRC-suite R7 trio; F4 owns the two add-guard flips) — P-D verifies those dispositions landed and enumerates the rest. R19's reversal likewise. Enumeration table as a file comment atop the class; version-cap collision (consent loser + previous park) asserted if not already in F1b.

- [ ] 1. Commit the enumeration table (`test(queue): R-net re-derivation map`), then work MARK-group by group, suite green after each, one commit per group.

### Task P-E: DESIGN.md rewrite — Sonnet, track E (worktree `…-e`)

**Files:** `DESIGN.md` ONLY. Rewrite as the app's visual law from the handoff (tokens light+dark, typography, spacing/radii/shadows, motion, component inventory, per-screen structure, copy register). **Preserve a Focus (Accessibility) section with the 2px accent outline requirement** (stray-focus-ring invariant anchor). Numbered sections with a header index so I2 re-anchors deterministically.

- [ ] 1. Rewrite; token-for-token self-check against handoff README; commit `docs(design): rewrite DESIGN.md to unified-queue redesign`.

---

## Phase I — serial integration (LCW worktree, after all tracks merge)

### Task I1a: Wire the shell — Opus

**Files:** Modify `Sources/Toolbox/App/RootView.swift` (single pane: mount `QueueView`, plugging P-B's views into ALL EIGHT frozen seam slots — quality/ocrOptions/perFile/versions/changeQuality/scanConsent/recentBatches/about; `SelfUpdater` wired with `isBusy: { model.isRunning }`; `UpdateBanner(release:updater:)` mounted above the queue content, sliding per the handoff's banner motion; window-level drop), `ToolboxApp.swift` (app-menu About via `CommandGroup(replacing: .appInfo)` toggling an `@State` hoisted to `ToolboxApp` and passed into `RootView` — ONE presentation state shared with the `⋯` menu item, so the two entry points cannot both present), `WindowConfigurator.swift` (min 900×640 — **PRESERVE `installStrayFocusClear(on:)` + `installArmingObserver()` untouched**, the window net of the stray-focus-ring invariant). Run `xcodegen`.

- [ ] 1. Wire, build, full suite PASS. Commit: `feat(app): single-window unified-queue shell`.

### Task I1b: Delete legacy + orphan sweep — Sonnet

**Files:** Delete `App/SidebarView.swift`, `App/Tool.swift`, `Compress/CompressView.swift`, `Compress/VersionsPopover.swift` (superseded by P-B's `VersionsPopoverContent`; its sole consumer `CompressView` dies in this same task), `OCR/OCRView.swift`, `OCR/OCRViewModel.swift`, `Tests/ToolboxTests/OCRViewModelTests.swift` (its cancel invariant lives on as `QueuePassTests.testCancelStopsQueue`), `Tests/ToolboxTests/BatchProgressTextTests.swift` (subject deleted). From `Components.swift`: `FileRow`, `DropZone`, `ToolHeader`, `SegmentedPreset`, `SegmentedPresetOption`, `SuccessBanner`, `ToolIconTile`, `Card`, `LinearProgress`, `batchProgressText` — then a zero-consumer sweep over ALL of `Components.swift` (grep each remaining symbol; delete any orphan). `xcodegen`.

- [ ] 1. Grep-verify zero consumers per deletion first; delete; build; full suite PASS. Commit: `chore(app): delete sidebar and legacy tool views`.

### Task I2: Docs, citations, DECISIONS, smoke, focus test — Sonnet

- [ ] 1. Citation sweep: `rg -n "DESIGN\.md"` repo-wide outside `.claude/` — 44 matching lines / 45 occurrences pre-sweep; re-anchor every reference in `Sources/` + `scripts/` (42 occurrences); `CODE_GUIDELINES.md`'s 3 mentions are a HUMAN doc — read-only, and none is a `§N` citation, so no edit needed. Zero stale references after. Commit.
- [ ] 2. `UpdateChecker`/`SelfUpdater` doc comments + `.claude/OVERVIEW.md` boundary table: user-initiated download path. `DECISIONS.md` entries: self-update posture reversal; MRC R7 asymmetry removal; deferral fulfilments (combined pass, per-file overrides, drag-during-run, history). Cite `**Spec:** .claude/specs/20260730-ui-redesign.md`. Commit.
- [ ] 3. `CompressSmoke`: compound-shape assertion (`outcome.compress` non-nil, `after < before`). Commit.
- [ ] 4. Focus-ring net check: add `WindowSetupFocusTests` asserting the arming observer installs and a `.plain`-styled probe control carries `clearsClickFocus` behaviour at the mechanism level; the BEHAVIOURAL check (popover-close keyboard walk) is V1's protocol — spec §9's "regression test stays green" is satisfied by this pair. Commit.

### Task I3: Gates + integration — Sonnet

- [ ] 1. All SEVEN `GATES.md` gates: `project-generates`, `ghostscript-builds`, `ghostscript-self-contained`, build, `tests` (mandated-by-human), `packaged-app-compresses`, `no-personal-corpus-references`. Green or stop-red.
- [ ] 2. Fixture-server updater functional pass (spec §11): build installed into `~/Applications`, one real update, old instance exits, new version relaunches.

### Task V1: Visual verification — orchestrator-owned, bounded

Owner: the LCW orchestrator (not a track). Protocol: build, drive with computer-use, capture all 14 screens light + dark, side-by-side against `renders/screen-*.png`; include the stray-focus-ring keyboard walk (open/close every popover and sheet via keyboard, no blue ring residue). Budget: up to THREE fix-and-recompare iterations per screen; a screen still divergent after three → stop-red to the human with the comparison pair. Then the private-corpus functional pass (spec §11), then review-team gate → PR.

---

## Self-review notes

- Spec coverage re-walked after revision: §6.1→F4, §6.2→F5a, §6.3→F1, §6.4→F3+F5a+F1b, §6.5→F4+F5a, §6.6→F4, §6.7→F5d, §6.8→F5c+F5a(semaphore), §6.9→F6, §6.10→P-C(+I1a busy-wire, I3 functional), §6.11→I1b, §7 screens→P-A/P-B+F5b(consent), §8→F7/P-E/I2, §9→F7+P-A/P-B a11y steps+I2 step 4+V1, §11→P-D/I3/V1, §13 acceptance 1→V1 (owner + budget).
- Type-consistency pass: `RowProblem` defined in F1 (Models) and consumed by F4's `RowInspection` and F1's `CompressOutcome.skipped`; `OCRing`/`StubOCREngine` defined F3/F4 before F5a consumes; seam signatures in P-A's Produces match P-B's Produces one-for-one (eight slots, `(ToolJob.ID) -> AnyView` where a row id is needed); `measuredPageRate` produced F5c, consumed P-B.
- Topological order: F1→F1b→F2→F3→F4→F5a→F5b→F5c→F5d→F6→F7 all serial; every P-track consumes only F-phase symbols; I1a consumes P-A+P-B+P-C merges.
- File-list completeness derived by grep (F1's ~82 test sites; I1b's orphan list), not recall.

## Gate rounds

- **R5 (incremental, Opus): NO-SHIP** — 1 critical (the spec's R7-asymmetry reversal had NO implementing task while the plan ordered its contradicting MRC-suite test to stay green — engine retention change + three test dispositions now in F2, consent-fires-regardless VM test in F5b) + 8 majors (F4 owns the two add-guard flips + its full file list; P-D's protocol widened to mechanism-symbol greps with flips staying with their owners; nine prose-only test names folded into F5a's manifest; rescue-leg .alreadySearchable/.tooFaint dispositions added; savings-sum exclusion restated in F5c/F6/P-A with the two sum tests moved where the sums exist; three missing ledger-invalidation legs added to F4; bannerDismissed per-version persistence given to P-C; warn/degraded classification defined — RowOutcome.isDegraded + StatusIndicator.Kind.warn) + 9 minors (run-guard-survives note, two updater fixture legs, batch verb floor test, Clear release + re-add test, engine-return→commit cancel test, banked-cancel history test, consent-undo assertion, divergence list completed with owners, BatchProgressTextTests dispositions re-homed to F5c). Lesson-candidates: map every spec change-table row to an owning task; a task's step manifest is the executable instruction — prose-only test names are dropped tests; a guard-relaxing foundation task owns every test of that guard; aggregate rules restate in every task computing the aggregate; sweep plans against spec §7/§10 state inventories, not §11 alone.
- **R4 (incremental, Opus): NO-SHIP** — 4 majors (legacy `VersionsPopover` shim added to F1b with `.originalReference` filtered; §6.4 `.alreadySearchable` labelling + §6.5 contingency suffix RAISED AS SPEC ESCAPES to the human — plan may not amend the spec by fiat, both marked PENDING with F5a blocked on them; freeze-port step deleted as unbased — the pattern lives in `CompressView.swift` and the redesigned popover has no Quick-Look surface; "Compare versions…" given an owner, pair rule, disabled state and test in P-B) + 6 minors (Consumes rename, `compressFailed` single-attribution to F1 + inspection-ignores clause, `reserveDelivery`/`releaseDelivery` declared in F4's Produces, divergence framing corrected, capsule `count > 1` gate pinned with F7 as enforcer, `useCard(.originalReference)` failure disposition + test). Lesson-candidates: a reviewer's prior request is not authority — re-derive from the design source; tuple label changes are API breaks — sweep every `.<label>` consumer; a plan that finds the spec wrong reports, never refines; every visible design element needs a named owner; always-present rows re-open every count-derived string and gate.
- **R3 (incremental, Opus): NO-SHIP** — 4 majors (F1b assertion accounting corrected to eight + arity re-baseline moved to F5a; two superseded capsule-label tests re-targeted with recorded handoff authority; `searchableBySlot` key space → `VersionCardKey` display identity incl. `originalReference` + `useCard` semantics; contingency `-ocr` name now reserved through the main-actor ledger mid-run, one-name-per-job preserved) + 9 minors (eight-slot residues, async redirect delegate variant + cancel semantics, continuation copy recorded as divergence + `RowProblem.compressFailed`, error-taxonomy default clause, `.alreadySearchable` honesty clause, app-menu About mechanism, dead citations re-anchored at F1b, `searchableByCard` default, freeze-pattern port step + test, this footer added). Lesson-candidates: per-assertion task attribution in re-baselines; count render rows against key spaces; contingency paths name their reserving task; adopted copy can retire prior invariants — state the outcome; delegate signatures must compile with their prescribed body.
- **R2 (incremental, Opus): NO-SHIP** — all 24 R1 findings confirmed fixed; 4 new majors (unproduced `searchableBySlot`/`originalURL`; F1b breakage outside its file list; in-place `VersionsPopover` rewrite with live out-of-track consumer; missing About seam slot / doubly-assigned `⋯` menu) + 7 minors, all applied.
- **R1 (full read, Opus): NO-SHIP** — 14 majors (track-boundary break on `VersionStore`; unfrozen P-A↔P-B seam; understated file lists; dropped spec cases; `finalBytes` ownership; missing doubles + OCR seam; incomplete F7 inventory; stale/wide updater host pin — live-probed; missing update-during-run gate; half-done estimator calibration; oversized F5/I1; unprotected focus-ring nets; unowned visual verification) + 10 minors, all applied.
