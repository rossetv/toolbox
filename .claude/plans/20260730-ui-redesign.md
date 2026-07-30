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
- All numbers in UI `.monospacedDigit()`. Copy verbatim from the handoff except spec-recorded divergences (§6.3 "grew", §6.8 footer line, honest variant labels, §7 consent copy) plus the plan/spec-recorded divergences, each with an owner: the rescue meta "Couldn't be compressed — made searchable instead" (F5a), the noGain composites "Already optimised · made searchable" and "Already optimised · too faint to read" (F5a), the compress-failure-with-OCR-off problem-row line "Couldn't be compressed" + Skip/Remove (F5a; P-A renders), and the versions-popover searchability suffixes " · Not searchable" / " · Searchable" (P-B) — no handoff strings exist for these states.
- Never delete/skip a failing gate test. All seven `GATES.md` gates must be green before the review-team gate.
- TDD per task: failing test → run (expect FAIL) → implement → run (expect PASS) → commit. Small conventional commits, one logical change each.
- Worktrees: foundation + integration tasks run in the LCW worktree (`.claude/worktrees/ui-redesign`, branch `feat/ui-redesign`). Parallel tracks run in their own worktrees under `.claude/worktrees/` branched off `feat/ui-redesign`, merged back on completion. **EVERY worktree (LCW + P-A…P-E) must obtain `Resources/ghostscript` BEFORE its first `xcodegen`** — it is gitignored (26 MB, absent from fresh worktrees), `project.yml` errors on the missing path, and the hosted test bundle needs the gs copy: run `scripts/build-ghostscript.sh` (PRIMARY route — idempotent, exits early on a matching binary; a real directory is what the three gs gates and the bundle-copy phase are proven against), or COPY from the main checkout (`cp -R ../../../../Resources/ghostscript Resources/ghostscript` — four levels from a worktree under `.claude/worktrees/`, measured; a real directory matches the trailing-slash gitignore pattern, works offline, and is byte-identical to what the gs gates are proven against — never a symlink, which the directory-scoped ignore rule does NOT match and a track's `git add -A` would commit).
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
    var bytes: Int                   // VAR: F5a re-stats EVERY variant the job appended to — recorded
                                     // FileVersions take the re-stat'd sizes (shipped card = finalBytes);
                                     // pre-append numbers on the popover/consent cards are wrong numbers
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
    var shippedVariant: EngineVariant?           // which variant WON and shipped (.mrc/.plain) — three live consumers
                                                 // read it (recompressPrediction's R16 calibration, switch direction,
                                                 // rerunForSwitch's tail); set by the engine (F2) from the winner
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
- [ ] 2. Implement; delete `JobOutcome`; bridge every switch/return site with equivalent behaviour: old `.compressed(b,a)` → `RowOutcome(originalBytes: b, finalBytes: a, compress: .compressed(before: b, after: a))`; old `.compressedHeavy(b,a,r)` → same + `shippedVariant: .mrc` + `runnerUp: .init(kind: r == b ? .original : .plain, bytes: r, searchable: false)` (the `.mrc` kind belongs to the SHIPPED winner; the parked loser is `.plain` or `.original` — inverting this is the exact bridge bug to avoid); old `.ocrAdded(p,s)` → `RowOutcome(originalBytes: n, finalBytes: n, ocr: .added(pages: p, skipped: s))` for `p > 0`, and `.tooFaint` for `p == 0` (F3 pins the partition; the bridge must not map the tooFaint engine fact to `.added`); old `.alreadySearchable`/`.noGain` likewise.
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
// (originalReference appears when originalURL != nil AND shipped?.variant != .original AND no parked
//  version already IS the original — never two rows for the same file, incl. after a use-Original switch;
//  F1b's own testOriginalReferenceHiddenWhenShippedIsOriginalDirect constructs the state directly). capsuleTitle: "N versions" per handoff screen 06/07 —
//  the capsule renders ONLY when a PARKED version exists (`runnerUp != nil || previous != nil`) —
//  NOT on cards.count > 1: with the always-present reference, every delivered row has count ≥ 2, and
//  renders screen-06/07 show NO capsule on the plain compressed row. capsuleTitle still counts the
//  reference (the rebuilt row reads "3 versions"). A row with no parked variant has no capsule and
//  no popover — the design's behaviour; §6.4's "always-present Original reference row" is a claim
//  about popovers that OPEN, never that every row has one. F7's QueueRow enforces the gate.
// VersionStore gains the mutators F5a drives:
func setOriginalURL(_ url: URL, for id: ToolJob.ID)
func setSearchable(_ searchable: Bool, card: VersionCardKey, for id: ToolJob.ID)
```
**Stated test outcomes (loop rule — no silent drops):** `testCapsuleTitleFlipsOnSwitch` and `testCapsuleTitleReadsOriginalWhenRunnerUpIsInput` become tautologies under the static `"N versions"` label — the R15 dynamic-label family is SUPERSEDED by the handoff (authority: spec §5's radio-list supersession + handoff screens 06/07), and the honest-label invariant they proved now lives on the popover rows: **re-target** them as `testShippedCardFlipsOnSwitch` (cards' shipped entry's variant flips across a switch) and `testCardsSurfaceOriginalKindParkedVariant` (a parked `.original`-kind version surfaces with its kind intact).

**Steps:**
- [ ] 1. `swapShipped(with:for:)` PERMUTES the two keys' `searchableByCard` flags along with the descriptions it already moves (an instant switch must never leave the old flag on the new bytes — acceptance criterion 3). Extend `VersionStoreTests`: `testSwapShippedPermutesSearchableFlags`, `testCardsIncludeOriginalReference`, `testNoDuplicateRowWhenParkedVariantIsOriginal` (parked `.original` kind → 3 rows, not 4), `testSearchableByCardEmptyMeansNoLabels`, `testSetSearchablePerCard`, `testConsentRetentionPlusPreviousParkStaysWithinCap` (runner-up + previous occupied → cards = 4 incl. reference, never 5); re-target the two superseded tests as stated above. FAIL → implement → PASS.
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
              progress: @escaping (Double) -> Void) async throws -> RowOutcome
```
(The ENGINE returns `RowOutcome` — `JobResult` stays the queue body's wrapper; the withhold/retention signal is `RowOutcome.runnerUp`; URLs stay caller-owned. `Compressing` re-types identically; `CompressSmoke` switches on the returned outcome. The queue body attaches `alternateURL` whenever `outcome.runnerUp != nil` — NEVER keyed on `shippedVariant` or on which variant won; keying on the winner silently reinstates the R7 asymmetry.)
Rules (spec §7 Per-file settings): `rebuildScan == true` never overrides classification eligibility (`.scanColour` only, complex-page rules stand — MRC R2); `preset == .maximumQuality` forces the MRC leg off regardless (MRC D3). Withhold rule, scoped VERBATIM to spec §6.3: a would-be runner-up that is a **COMPRESS variant** ≥ input is withheld (no `alternateOutput` write, no descriptor); the **untouched-original park** (`runnerUpBytes == inputSize`, gs bloated — DECISIONS 2026-07-24's marker) is NOT a compress artefact and is RETAINED, spec §6.4. Winner ≥ input → `.noGain` (as today). `finalBytes` in the returned outcome = compress artefact size (F1's ownership note — F5a re-stats after OCR).

**Steps:**
- [ ] 1. Extend `CompressEngineTests`: `testRebuildScanFalseSkipsMRCOnScanColour`, `testRebuildScanTrueDoesNotForceIneligible` (bornDigital + `true` → plain Rung-1 — opt-in never overrides eligibility), `testRebuildScanIgnoredAtMaximumQuality`, `testRunnerUpAtOrAboveInputWithheld` (verifier override forces a bloated variant → `runnerUp == nil`). Run: FAIL.
- [ ] 1b. **R7-asymmetry reversal (spec §5 change table — an ENGINE behaviour change)**: when a valid hybrid AND a valid gs output both exist, the gate LOSER is retained to `alternateOutput` regardless of which won (today the losing hybrid is discarded). The loser is retained ONLY after `validatesOffPool` passes on it — run in the fall-through branch (today's short-circuit means validation NEVER runs on the hybrid-lost path; hoisting it above the size gate would add a page-render pass to every MRC document — don't). New `CompressEngineMRCTests.testHybridLostGateStillWritesRunnerUp` (valid hybrid lost ⇒ runner-up file written + descriptor present, kind `.mrc`) + `testInvalidHybridLostGateWritesNoRunnerUp` (validation fails on the loser ⇒ no `alternateOutput` file, `runnerUp == nil`). Dispositions for ALL EIGHT alternate-asserting MRC-suite tests (grep-derived, `grep -n alternate`): `testHybridLargerThanGsShipsGsOutput` — SUPERSEDED by the new test; `testHybridSmallerThanGsShipsHybridWithRunnerUp` — ADAPTS unchanged (hybrid-won retention already true); `testHybridWinsButGsCandidateNotSmallerThanInputParksOriginalAsRunnerUp` — ADAPTS UNCHANGED (the original park SURVIVES the withhold rule, see Rules); `testMRCInternalFailureShipsGsSilently` — ADAPTS unchanged (no valid hybrid exists ⇒ retention cannot fire; spec §11's hybrid-never-wins sibling); `testNeverLargerThanInputStillHolds` — ADAPTS unchanged (no-gain path: nothing valid to retain); `testScanColourOnMaximumQualityNeverAttemptsMRC`, `testScanBilevelStillRoutesToRungTwo`, `testCancelDuringRungThreeDeliversNoOutput` — ADAPT unchanged (no hybrid built on these paths). Run: FAIL → implement → PASS.
- [ ] 2. Implement (`let wantsMRC = (rebuildScan ?? true) && classification == .scanColour && preset != .maximumQuality`; withhold at the `alternateOutput` copy site; descriptor kind from which variant parked). Run: PASS. Full engine suite: PASS.
- [ ] 3. Commit: `feat(compress): per-file rebuildScan override and >=input variant withhold`.

### Task F3: OCR split + `OCRing` seam — Opus, foundation

**Files:**
- Modify: `Sources/Toolbox/OCR/OCREngine.swift`, `Sources/Toolbox/OCR/OCROptions.swift` (curated language list)
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
Geometry rule: boxes are normalised → they project onto the TARGET's own page geometry (derive per-page geometry from the target at append time; composed MRC/bilevel pages are origin-(0,0), rotation-0, MediaBox = raster size). Page-count mismatch → `OCRError.validationFailed`. `ocr(_:to:options:progress:)` remains, re-expressed as recognise+append (OCR-only path behaviour identical). Verbatim-prefix validation runs per append. **`RecognisedDocument` → `OCROutcome` partition, pinned HERE as a NAMED SYMBOL** (F5a's leg reads `recognised.outcome` — it may not inline the mapping): `RecognisedDocument` gains `let pageCount: Int` and `var outcome: OCROutcome { pagesRecognised == 0 && pagesSkipped == pageCount ? .alreadySearchable : (pagesRecognised > 0 && pageText.isEmpty ? .tooFaint : .added(pages: pagesRecognised, skipped: pagesSkipped)) }` — test `testZeroRunRecognitionMapsToTooFaint` against the REAL engine, never the stub. `OCROptions` gains the curated language list the OCR popover renders (`static let curatedLanguages: [(code: String, display: String)]` — the handoff's eight + English).

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
func rebind(_ id: ToolJob.ID, to url: URL)   // Find it…: FULL state reset — re-runs add-time inspection
                                              // (clears problem, recomputes metaLine), resets the row to .queued
                                              // (incl. from .failed), re-analyses (no stale fallback estimate),
                                              // re-reserves; test testRebindClearsProblemAndRequeuesRow
func setSkipped(_ skipped: Bool, for id: ToolJob.ID)   // Problems-screen Skip: excluded from the run and from canStart's healthy count
@Published private(set) var armedExclusions: Set<ToolJob.ID> = []
func setArmedExclusion(_ excluded: Bool, for id: ToolJob.ID)   // Change-quality "Choose which files…": excluded rows report .none from recompressState (test leg in step 3)
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
- [ ] 3. Write `QueueAdmissionTests`: `testAddDuringRunJoinsBatch`, `testAddDuringRunReservesAgainstLockedSettings`, `testReservationReleasedOnRemove`, `testClearReleasesReservationsAndReAddDoesNotSuffix`, `testFolderChangeReReservesWhileIdle`, `testVerbSetChangeFlipsSuffix` (compress-on → `-compressed.pdf`; toggle to OCR-only while idle → re-reserved `-ocr.pdf`), `testPerRowOCROverrideFlipsSuffix`, `testRebuildScanFlipAddsAndRemovesAlternateReservation`, `testRebindReReservesWhileIdle`, `testRebindClearsProblemAndRequeuesRow` (leaves the problem set, re-enters canStart's healthy count, non-fallback estimate), `testOverrideVerbFloorBlocksLastVerbOff`, `testZeroVerbsDisablesStart`, `testProblemRowExcludedFromCanStart`. Run: FAIL.
- [ ] 4. Implement part-1 surface. Run: PASS. Full suite: PASS.
- [ ] 5. **Row-scope the preset-keyed state (spec §6.1, binding)** — the re-point list is GREP-DERIVED over every batch-`preset` read incl. provenance WRITES: re-key `FutileAttempt` to `(id, effectivePreset, verbSet)`; point `recompressState(for:)`, `armedJobs`, `recompressPrediction(for:at:)` and the armed banner's arithmetic at `effectivePreset(for:)`; `publishJobs()` keys the row's displayed estimate by `effectivePreset(for: job.id)` (the batch-preset estimate on an overridden row is two different numbers for one file — fix at the VM publish site, never the footer); `compress()`'s allocation pass seeds `pendingPresets[job.id] = effectivePreset(for: job.id)` (R16 provenance re-derived per-row — a wrongly-recorded `lastAttemptPreset` defeats the re-pointed `recompressState` from the other side). Tests `testArmingUsesRowEffectivePreset`, `testFutilityKeyIncludesVerbSet`, `testOverriddenRowEstimateUsesRowPreset`, `testOverriddenRowRecordsItsOwnPresetAsProvenance`. Existing arming/futility tests in `QueueViewModelTests` whose premise is batch-keyed get stated dispositions in this task (adapt — same invariant through `effectivePreset`, which equals the batch preset when no override exists). Run: PASS. Full suite: PASS.
- [ ] 6. Commit: `feat(queue): verbs, overrides, add-time inspection and reservation`.

### Task F5a: Single-pass job body — Opus, foundation

**Files:** Modify `Sources/Toolbox/Queue/QueueViewModel.swift` (`RowProblem.compressFailed` is F1's definition — F5a only PRODUCES it). Tests: `Tests/ToolboxTests/QueuePassTests.swift` (new) + `Tests/ToolboxTests/QueueViewModelTests.swift` (re-baseline: `row.count` 2 → 3 where the Original reference row now appears AND the paired `capsuleTitle` assertion in the same test body ("2 versions" → "3 versions") — `originalURL` is populated from this task on; `VersionStoreTests`' own `count == 3` stays 3, that test constructs `RowVersions` directly and never sets `originalURL`).

Job body per file (spec §6.2/§6.4/§6.5/§6.8): compress leg (when effective-on, per-row `preset`/`rebuildScan`) → cancellation check → OCR leg (when effective-on; width-2 semaphore; `recognise` from ORIGINAL, `append` to delivered file via temp + `replaceItemAt`, and to a retained runner-up variant file; `.original`-kind runner-up NEVER appended; append failure → `searchable = false`, never a job failure) → cancellation check → re-stat `finalBytes` AND every appended variant's bytes (`runnerUp.bytes` + each recorded `FileVersion`; the shipped card takes `finalBytes` — the consent sheet's two cards must be measured at the same moment), commit. Cancel between legs → `.ocr = .cancelled`, kept-and-banked. Tests `testRunnerUpBytesRestatedAfterAppend`, `testShippedCardBytesMatchRowFinalBytes`.

**Recognise-failure on the compress-delivered path** (spec §7's degraded family): a `.failed` OCR outcome after a successful compress delivery NEVER fails the job — the compressed file is kept and banked, `ocr = .failed(msg)`, row classified degraded; test `testCompressDeliveredOCRRecogniseFailureIsDegradedNotFailed`. **OCR-off compress failure**: OCR effective-off + `ghostscriptFailed`/`validationFailed` → the throw propagates → `JobState.failed("Couldn't be compressed")` — `RowProblem.compressFailed` is NOT the carrier there (it stays meta-line-only for the rescue); test `testCompressFailureWithOCROffFailsRow`.
**Producer duties pinned here**: the commit step populates F1b's new state — `setOriginalURL(job.url)`, then `setSearchable` per card from the append results: `.shipped`/`.runnerUp`/`.previous` = did that file's append succeed; `.originalReference` (and any `.original`-KIND parked version) = `ocr == .alreadySearchable` — **[SPEC AMENDED 2026-07-30, panel verdict + DECISIONS entry: §6.4 is outcome-keyed — the Original row is labelled searchable iff the OCR leg returned `.alreadySearchable`; "searchable" = extractable text layer on every page, keyed to the recorded outcome, never a fresh probe; the shipped-unsearchable/Original-searchable corollary is legal and tested (`testShippedUnsearchableOriginalSearchableCorollary`)]**; no OCR leg ran → no `setSearchable` calls at all (empty map = no labels). **Selecting the Original reference row** (design screen 07 makes it a radio target): `func useCard(_ key: VersionCardKey, for job: ToolJob) async` maps `.runnerUp`/`.previous` onto the existing `useVersion`; `.originalReference` uses the repo's EXISTING atomic sequence — never a bespoke park-then-copy (the naive order lets `setSlot`'s discard delete the displaced previous BEFORE the copy is attempted, unrecoverably): copy the original to a temp beside the delivered file, then `store.promote(fresh: temp, to: shipped.url, parking: versionStore.reservePreviousURL(…))` (the recompress commit's own primitive — park-first, atomic, cross-volume-safe), then `setSlot(.previous, …)`/`setShipped` + the flag permutation; on throw record NOTHING and take `SwitchError.shippedStranded(parked:)`'s existing path for the "row states where the file is" copy (promote's third step is best-effort by design — a missing parked file is a designed-for state). The original in its own folder is NEVER touched; no re-append. THREE companion rules, each acceptance-criterion-3-load-bearing: (1) the flag permutation runs ONLY when `searchableByCard` is non-empty (OCR ran for this row) — it MOVES `[.shipped]` → `[.previous]` and writes `[.shipped] = searchableByCard[.originalReference] ?? false`; on an empty map it writes NOTHING (spec §6.4: a compress-only row carries no claim in either direction — a `?? false` default would manufacture one; test `testUseOriginalOnCompressOnlyRowWritesNoLabels`); (2) the reference row is GATED on `shipped?.variant != .original` as well as the no-parked-original rule, and `useCard(.originalReference)` is a NO-OP when `shipped?.variant == .original` (else two clicks list the original twice and the second discards the row's compressed version); (3) the synthesised reference `FileVersion` is pinned: bytes = `originalBytes`, variant = `.original`, preset = the row's `rowPreset`. GUARDS, branch-split (delegating to a guarded method means INHERITING its guard, never re-taking it — a re-entrancy flag set twice is a silent no-op, not double safety): for `.runnerUp`/`.previous`, `useCard` performs NO guard and NO insert — `useVersion` owns both (it checks and inserts in its own synchronous prefix); for `.originalReference` ONLY, `useCard` carries `guard !isRunning`, `guard !switchesInFlight.contains(id)`, then `switchesInFlight.insert(id)` + its own `defer { switchesInFlight.remove(id) }` (no rerunForSwitch hand-off exists on this path, so nothing else clears it); `.shipped` → no-op (already in use): no guard, no insert, no state change — the partition covers all four keys. Tests `testSecondUseOriginalWhileFirstInFlightIsIgnored` + `testUseCardDelegatesRunnerUpSwitchSuccessfully` (the delegated switch must actually switch — the double-guard no-op ships silently otherwise). Tests `testUseOriginalParksShippedIntoPreviousReplacingOccupant`, `testUseOriginalReferenceMovesSearchableFlags`, `testOriginalReferenceHiddenWhenShippedIsOriginal`, `testSecondUseOriginalIsNoOpAndKeepsCompressedVersion`. **Failure disposition, promote-shaped** (the store owns every park/restore — a VM-level restore duplicates a step the primitive already performs): temp-copy fails → nothing has moved, record nothing, plain switch failure; `promote` throws an ordinary error → shipped file untouched by the store's contract, record nothing; `promote` throws `SwitchError.shippedStranded(parked:)` → surface it through the existing `reportSwitchFailure` path (its message already names the park path), delete nothing. Tests `testUseOriginalReferenceCopiesNeverMoves`, `testUseOriginalReferencePromoteFailureRecordsNothing`, `testUseOriginalReferenceStrandedReportsParkedPath`. **Rescue-leg no-delivery dispositions (spec §6.5)**: `.alreadySearchable`/`.tooFaint` on the rescue leg release the `-ocr` reservation, deliver nothing, and take the OCR-only pipeline's disposition (warn/degraded, copy naming the compress failure) — tests `testRescueAlreadySearchableShipsNothing`, `testRescueTooFaintShipsNothing`. Sum exclusions are asserted where the sums exist: `testOCROnlyAndRescuedRowsExcludedFromSavedSoFar` (F5c) and `testOCROnlyAndRescuedRowsExcludedFromSavedBytes` (F6) — F5a itself asserts only the row-level classification.
**`CompressOutcome.skipped(problem:)` producer**: a compress-specific failure (`CompressError.ghostscriptFailed`/`.validationFailed`) while OCR is effective-on does NOT fail the job — the body reserves a contingency `-ocr` name through F4's `reserveDelivery(suffix:for:)` (the SAME main-actor ledger that serves mid-run adds — no filesystem race; the `-compressed` reservation is released via `releaseDelivery(for:)`, so one name per job ships). **[SPEC AMENDED 2026-07-30, panel verdict + DECISIONS entry: §6.5 gains the compress-failure OCR rescue with five binding pins — rescued row classified warn/degraded, NEVER "failed" (Problems footer stays true); counts as OCR-only in every savings sum (grey "no change", never toward "N MB saved"); rescue-leg OCR failure releases BOTH reservations and fails to a problem row (worst case = no-rescue); encrypted/corrupt fail the whole job; compress failure with OCR OFF fails the row with a recorded copy-divergence problem line. Tests add `testRescuedRowClassifiedWarnNotFailed`, `testRescueOCRFailureReleasesBothReservations`; counted-as-OCR-only is asserted by `testOCROnlyAndRescuedRowsExcludedFromSavedSoFar` (F5c) / `…FromSavedBytes` (F6)]**. The SAME mid-run reservation switch serves the sibling carve (spec §6.5 amended, pinned in full): a `noGain` compress verdict with OCR effective-on and outcome `.added` delivers original-plus-layer under `-ocr.pdf`; the row is an OCR-only delivery (grey sizes, excluded from every savings sum — asserted by F5c's `testOCROnlyAndRescuedRowsExcludedFromSavedSoFar` and F6's `testOCROnlyAndRescuedRowsExcludedFromSavedBytes` — counts via `searchableCount`, meta "Already optimised · made searchable"); `.alreadySearchable` → nothing ships, both reservations released, unchanged row; `.tooFaint` → nothing ships, degraded warn row; `.failed` → both reservations released, job fails, original untouched. It continues the OCR leg against the ORIGINAL and commits `compress = .skipped(problem: .compressFailed)` (defined in F1; its ONLY consumer is the row meta line — never problem-row tint/copy) with meta "Couldn't be compressed — made searchable instead" (recorded copy divergence). `CompressError.encrypted`/`.corrupt` fail the whole job (OCR would fail identically) → problem row. **Any other throw (`.sameInputOutput`, `CancellationError`, non-`CompressError`) propagates out of the body unchanged — never the OCR continuation.**

- [ ] 1. Write `QueuePassTests`: `testCompressThenOCRSingleRow`, `testOCRAppliedToRunnerUpVariant` (both files carry layer, assert `pageHasText` each), `testOriginalVariantNeverAppended` (file untouched, `searchable == false`), `testSearchableByCardReflectsAppendOutcomes` (incl. empty-map when OCR off), `testUseOriginalReferenceCopiesNeverMoves`, `testCompressFailureContinuesOCRLeg` (stub throws `ghostscriptFailed`; OCR on → contingency `-ocr` reservation through the ledger, output delivered, `compress == .skipped(problem: .compressFailed)`, `-compressed` reservation released), `testEncryptedFailsWholeJob`, `testCancelBetweenLegsBanksCompressed` (asserts `.ocr == .cancelled` + file kept), `testCancelStopsQueue` (successor to `OCRViewModelTests.testCancelStopsTheViewModelsQueue` — no further job starts after cancel), `testOCROnlyRowNoSizeLie`, `testOCRSemaphoreWidthTwo` (4 jobs, gated `StubOCREngine` → ≤2 concurrent in OCR leg), `testFinalBytesRestatedAfterAppend`, `testCancelBetweenEngineReturnAndCommit`, plus every prose-named test above folded into THIS manifest: `testShippedUnsearchableOriginalSearchableCorollary`, `testRescuedRowClassifiedWarnNotFailed` (asserts `isDegraded` true AND state ≠ `.failed`), `testRescueAlreadySearchableShipsNothing`, `testRescueTooFaintShipsNothing`, `testRescueOCRFailureReleasesBothReservations`, `testNoGainWithOCRDeliversOcrName`, `testNoGainAlreadySearchableShipsNothing`, `testNoGainTooFaintShipsNothing` (nothing ships, both reservations released, degraded warn row), `testNoGainOCRFailureReleasesBothReservations` (the two SUM-exclusion tests live in F5c/F6 where the sums exist), `testCompressDeliveredOCRRecogniseFailureIsDegradedNotFailed` (file kept + banked, `isDegraded` true, state ≠ `.failed`), `testCompressFailureWithOCROffFailsRow`, `testRunnerUpBytesRestatedAfterAppend`, `testShippedCardBytesMatchRowFinalBytes`, `testUseOriginalParksShippedIntoPreviousReplacingOccupant`, `testUseOriginalReferenceMovesSearchableFlags`, `testOriginalReferenceHiddenWhenShippedIsOriginal`, `testSecondUseOriginalIsNoOpAndKeepsCompressedVersion`, `testUseOriginalOnCompressOnlyRowWritesNoLabels`, `testSecondUseOriginalWhileFirstInFlightIsIgnored`, `testUseCardDelegatesRunnerUpSwitchSuccessfully`, `testUseOriginalReferencePromoteFailureRecordsNothing`, `testUseOriginalReferenceStrandedReportsParkedPath`. Run: FAIL.
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
ETA: smoothed completed-fraction rate, nil until batch fraction ≥ 0.1; monotonic display. `batchProgress` PERSISTS after the run ends until the queue is cleared — test `testBatchProgressSurvivesBatchEnd` — rendering SPLIT: the "N MB saved" figure from `savedSoFarBytes`; the Finished header's before/after totals, file count and searchable count computed FROM ROWS (spec §7/§10) — P-A renders both sources, recomputes neither. **Per-row surfaces (handoff screen 05's "8s left" and "finished in 12 seconds" are data requirements)**: `func rowETASeconds(for id: ToolJob.ID) -> Int?` — nil before 10% of that row's CURRENT LEG (the spec's gate is per leg, not per batch) — and `func rowDuration(for id: ToolJob.ID) -> TimeInterval?` (completed duration recorded at commit; renders screen 05's "finished in 12 seconds"). Tests `testRowETANilBeforeTenPercentOfLeg`, `testRowDurationRecordedAtCompletion`.

- [ ] 1. Tests: aggregation, `testRowETANilBeforeTenPercentOfLeg`, `testRowDurationRecordedAtCompletion`, `testBatchProgressSurvivesBatchEnd`, monotonicity, per-leg labels, `measuredPageRate` recorded post-run, `testOCROnlyAndRescuedRowsExcludedFromSavedSoFar` (spec §6.5: `savedSoFarBytes` sums COMPRESSED rows only — OCR-only, rescued and noGain+OCR rows contribute zero), plus the three `BatchProgressTextTests` assertions re-homed here with stated outcomes in a file comment atop `BatchProgressTests` (counts-current-file → aggregation tests; clamps-at-finish → `testReadingPageLabelClampsAtPageCount` — the same off-by-one shape the old test documented, now on `legLabel`'s "Reading page N of M"; uses-given-verb → per-leg label tests). FAIL → implement → PASS. Commit: `feat(queue): batch progress and measured ETA`.

### Task F5d: Estimator MRC calibration — Opus, foundation

**Files:** Modify `Sources/Toolbox/Compress/CompressEstimator.swift` AND `Sources/Toolbox/Queue/QueueViewModel.swift` (the sole production caller — the new input must be wired, not defaulted-inert). Test: extend `Tests/ToolboxTests/EstimatorTests.swift` + `QueueAdmissionTests.swift`.

Two-part measurement (spec §6.7), in order:
- [ ] 1. Synthetic measurement: run the actual MRC pipeline on the repo's scanColour fixtures; record achieved reductions in the task log.
- [ ] 2. Corpus measurement: run the same on the private corpus; record FIGURES ONLY in `$(git rev-parse --path-format=absolute --git-common-dir)/lcw/20260730-ui-redesign/calibration.md` — never in the repo (`no-personal-corpus-references` gate).
- [ ] 3. Set `baseReduction[.scanColour]` from the measurements (untempered constants chosen so the TEMPERED prediction `base * (0.3 + 0.7 * payloadRatio)` lands within ±15% of measured on both sets; expected neighbourhood `.balanced` ≈ 0.75, `.smallestSize` ≈ 0.80 — the measurements decide). **`.maximumQuality` stays untouched at 0.12 — MRC never runs there (MRC D3), so an MRC-derived constant would predict what the engine cannot deliver.** Fallback if ±15% is unreachable with one constant: widen to ±25%, keep "about" phrasing, and record the achieved tolerance in the plan (edit this step's line with the final constants + tolerance).
- [ ] 4. The estimator's public entry is re-pinned as `analyse(_ input: URL, mrcEligible: Bool) async -> Analysis` (no default — a defaulted parameter makes the fix inert); eligibility mirrors F2's rule (`(rebuildScan ?? true) && contentType == .scanColour && preset != .maximumQuality`): MRC-class constants only when TRUE, today's constants otherwise (§6.7's honesty). THE VM (this task's second file) passes `effectiveVerbs`-consistent `(overrides[id]?.rebuildScan ?? true)` at every `analyse` call AND re-analyses the row when a `rebuildScan` override changes while idle (the analysis cache is per-file — a flip must re-price; sibling of F4's reservation invalidation). Tests: `testRebuildOptOutRepricesRowEstimate` (QueueAdmissionTests). `EstimatorTests`: `testScanColourPredictionMatchesMRCPipelineOnFixture` (tolerance per step 3), `testScanColourWithRebuildOptOutPredictsNonMRCReduction`, existing fallback tests still green. Commit: `feat(estimate): calibrate scanColour to the MRC path`. **Final constants recorded here post-measurement: ___ (implementer fills in).**

### Task F5e: Re-run paths — Opus, foundation

**Files:** Modify `Sources/Toolbox/Queue/QueueViewModel.swift` (`recompress(_:engine:)`, `rerunForSwitch`). Tests: extend `QueuePassTests.swift`.

The two non-batch `engine.compress` call sites inherit every batch-leg obligation: both route through F5a's leg sequence — recognise from the ORIGINAL, append to the regenerated winner AND any retained runner-up, `.original` never appended (spec §5 R19 reversal, §6.4, §7 "Re-runs re-apply OCR"); both pass the row's effective `rebuildScan` (never `nil` — a row's opt-out survives re-runs); `rerunForSwitch`'s `.compressedHeavy` keying is replaced by `outcome.shippedVariant` + `outcome.runnerUp.kind` for the shipped/parked mapping (F1's single inversion rule — never re-derived locally) (the R7 reversal makes the old "heavy shipped, runner-up parked" pairing invertible); the OCR leg publishes progress through `recompressProgress[id]`; the demoted shipped file's searchability flag CARRIES OVER to `.previous` (never recomputed) — and the NEW shipped card's flag (and `.runnerUp`'s where regenerated) is set from THIS re-run's own append result, exactly as F5a's batch commit does; a failed re-run append marks the shipped card unsearchable (acceptance criterion 3 has no exemption on the re-run path); regenerated variants' recorded bytes are re-stat'd post-append exactly as F5a's commit does.

- [ ] 1. Tests: `testChangeQualityReRunReAppliesOCR`, `testReRunHonoursRowRebuildOptOut`, `testRerunForSwitchMapsVariantsFromDescriptorKind`, `testPreviousSlotCarriesSearchabilityFlag`, `testReRunAppendFailureMarksShippedUnsearchable`. FAIL → implement → PASS. Full suite: PASS.
- [ ] 2. Commit: `feat(queue): re-run paths re-apply OCR and honour row overrides`.

### Task F6: HistoryStore — Sonnet, foundation

**Files:** Create `Sources/Toolbox/Queue/HistoryStore.swift`; modify `Sources/Toolbox/Queue/QueueViewModel.swift` (batch-end recording). Tests: `Tests/ToolboxTests/HistoryStoreTests.swift` (new) + extend `QueuePassTests.swift`.

Interfaces as specified — OWNERSHIP pinned: `QueueViewModel` exposes `let history: HistoryStore` (constructed in the VM's init; ONE instance; I1a wires `QueueView(model: model, history: model.history, …)` and the `recentBatches` slot receives `RecentBatchesSheet(history: model.history)` — never a second instance): `HistoryBatch` (id/date/folderName/folderURL/fileCount/presetTitle?/compressOn/ocrOn/savedBytes/searchableCount/partial/problem/cancelled), `HistoryStore: ObservableObject` (`batches` and `lifetimeSavedBytes` both `@Published private(set)` — the strip and sheet observe them; `init(directory: URL? = nil)` — nil → Application Support/Toolbox, the repo's `RunnerUpStore.rootOverride` test-seam pattern; the VM init gains `history: HistoryStore? = nil` likewise, and EVERY history test passes a temp directory (hermetic — never the developer's real history.json); `retentionLimit = 200` — covers months of heavy use at trivial size, bounds growth; `batches` newest-first; `lifetimeSavedBytes`; `record`; `clearList()` empties batches ONLY, lifetime survives — spec §6.9; `groupedByDay`). Disk envelope `{"version":1,…}`; foreign version → empty start, never overwrite until next record. VM records at batch end incl. cancel-with-banked; cancel-with-nothing-banked records nothing.

- [ ] 1. `HistoryStoreTests`: round-trip, `testClearListPreservesLifetime`, trim at 200, day grouping, corrupt/foreign-version → empty. FAIL → implement → PASS.
- [ ] 2. `QueuePassTests`: `testBatchEndRecordsHistory`, `testCancelledBatchWithBankedFileRecordsEntry`, `testCancelledEmptyBatchRecordsNothing`, `testOCROnlyAndRescuedRowsExcludedFromSavedBytes` (history `savedBytes` sums compressed rows only; rescued/noGain+OCR count via `searchableCount`). FAIL → wire → PASS.
- [ ] 3. Commit: `feat(history): recent-batches store with lifetime savings`.

### Task F7: Design system — tokens + full component inventory — Sonnet, foundation

**Files:** Modify `Sources/Toolbox/DesignSystem/Theme.swift`, `Components.swift` (restyle kept: `PrimaryButton`, `LinkButton`, `StatPill`, `PDFThumbnail`); create `Sources/Toolbox/DesignSystem/QueueComponents.swift`. Test: `Tests/ToolboxTests/ThemeTests.swift` (new).

Tokens (handoff README table, light+dark) — MAPPED ONTO THE EXISTING IDENTIFIERS, no rename (the handoff's bg/text2/text3 are `background`/`textSecondary`/`textTertiary`, read at 19 sites in five files outside this task's list; a comment atop `Theme.Colors` records the handoff-name → identifier mapping): values updated to the handoff's (incl. dark bg `#1c1c1e`, dark surface `#242426`, dark accent `#0a84ff`); NEW identifiers only for tokens with no incumbent: warn/danger/stroke/sep/hairline/fill/track; `Theme.Radius` row 10, control 8, popover 12, sheet 14, capsule 980; `Theme.Motion` standard spring(0.35, 0.85), hover .15, press .12, popover .3, sheet .38, banner .45, checkPop .45. The identifier mapping extends to EVERY namespace: `Theme.Radius` — handoff `capsule`(980)→incumbent `pill`, `popover`(12)→incumbent `card`, new names only where no incumbent (row 10, sheet 14); `Theme.Typography` — the incumbent `caption` case is RE-VALUED to the handoff's 11.5–12 (never redeclared — invalid redeclaration — and every surviving `.themeFont(.caption)` site is checked in the same step), adds windowHeadline/sheetTitle/rowName/bodyStrong/body13/meta/sectionLabel. The full handoff-name→identifier mapping is recorded in the comment atop `Theme` AND handed to P-E's brief (DESIGN.md must name the identifiers the CODE uses).

`QueueComponents.swift` — the COMPLETE control inventory for all 14 screens, DERIVED SCREEN-BY-SCREEN from `renders/screen-*.png` as this task's step 0 (a per-screen component map, committed as a comment atop the file; assembling from memory is how three shapes went missing) (P-A/P-B create no components; a missing one is a stop-and-report, never an improvisation):
```swift
struct VerbChip: View { let title: String; let suffix: String?; let isOn: Bool; let icon: Image
                        let toggle: () -> Void; let openOptions: (() -> Void)? }   // two actions, two VoiceOver labels
struct StatusIndicator: View { enum Kind { case finished; case active(Double); case queued; case unchanged; case warn }; let kind: Kind }   // .warn renders degraded rows (spec §6.5: rescued, tooFaint) — outline-warn glyph, warn tint
struct CapsuleProgressBar: View { let fraction: Double }
struct OptionCard: View { let title: String; let value: String; let caption: String
                          let captionTone: Tone; let isSelected: Bool; let action: () -> Void
                          enum Tone { case success, muted, plain } }
struct QueueRow: View { /* thumbnail, name, meta(+accent), 70pt trailing sizes column, hover+focus gear,
                           status slot, capsule; onOpen/onGear/onCapsule/onRemove; keyboard-focusable;
                           row CONTEXT MENU mirroring the hover affordances (spec §9's non-hover path: gear/settings, versions, remove);
                           PLUS the problem variant (handoff screen 10): tinted bg danger-7%/warn-10%,
                           inline secondary-button + link affordances (Find it… / Skip / Remove) */ }
struct BatchCard: View { let icon: StatusIndicator.Kind; let title: String; let subtitle: String
                         var trailingLink: (title: String, action: () -> Void)? = nil   // screen 01 "Open folder"
                         let action: () -> Void }
struct CapsuleBadge: View { let text: String; let tone: Tone; enum Tone { case accent, muted } }  // RECOMMENDED / BEST FOR SCANS / NOTHING REDRAWN
struct VariantCard: View { /* screen 09: badge + 22pt size + green percentage + PAGE-PREVIEW PANEL
                              (label-band-free page render — PDFThumbnail gains a `plain: Bool` mode)
                              + explanation paragraph + selected accent ring */ }
struct SecondaryButton: View { let title: String; var icon: Image? = nil; let action: () -> Void }
                        // handoff: shadow 0 .5px 1.5px rgba(0,0,0,.18) + inset ring; dark #3a3a3c
struct SegmentedRow: View { let options: [String]; @Binding var selection: Int }        // 04b Fast/Accurate, 04c quality
struct DropdownRow: View { let label: String; let options: [String]; @Binding var selection: String }  // 04b language
struct ToggleRow: View { let title: String; let stateLine: String; @Binding var isOn: Bool }            // 04c
struct RadioRow: View { let title: String; let subtitle: String; let isSelected: Bool
                        var subtitleTone: Tone = .plain
                        var trailingValue: String? = nil   // screen 04's right-aligned batch totals
                        var badge: String? = nil           // screen 04's RECOMMENDED capsule
                        let action: () -> Void; enum Tone { case plain, accent } } // 04 + 07
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

**Files (create only):** `Sources/Toolbox/Queue/QueueView.swift`, `EmptyStateView.swift`, `DragOverlayView.swift`, `QueueHeaderView.swift`, `QueueRowsView.swift`, `QueueFooterView.swift`. Test: `Tests/ToolboxTests/QueueViewStateTests.swift` (new). Footer sums render VM aggregates ONLY (`BatchProgress.savedSoFarBytes` etc.) — the OCR-only/rescued exclusion is F5c's rule; the footer never recomputes sums. When NO row contributes savings (all-OCR batch), the footer and Finished header render the searchable-count sentence in place of a megabyte figure — never "0 MB saved" (spec §6.3's forbidden string; renders/ has no such state so V1 cannot catch it) — asserted in `QueueViewStateTests.testAllOCRBatchFooterNeverSaysZeroSaved`. Degraded rows render `StatusIndicator.Kind.warn`. Label tests include one ABSENCE assertion: a compress-only row has no searchability subtitle in either direction.

**Interfaces — Consumes:** `QueueViewModel` (F4/F5 surface), `HistoryStore` (F6 — held as `@ObservedObject var history: HistoryStore` inside `QueueView`; a nested ObservableObject does NOT propagate through the VM's objectWillChange), `QueueComponents` (F7), `FilePicker`, `RowVersions` read-only. **Produces — the FROZEN injection seam (I1 plugs P-B's views into exactly these NINE slots; no other cross-track reference exists):**
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
         about: @escaping () -> AnyView,                   // About sheet content (⋯ menu + app menu)
         showAbout: Binding<Bool>)                         // ONE About presentation state — QueueView presents
                                                           // the sheet off this binding; the ⋯ item toggles it;
                                                           // ToolboxApp's CommandGroup toggles the SAME binding
}
```
P-A owns the `⋯` button AND its menu (Recent batches… → `recentBatches` slot; Where files are saved… → `FilePicker.chooseFolder()` directly, no view; About Toolbox → sets `showAbout`). NINE slots total (eight content closures + the About binding) — the freeze claim covers all of them; no other cross-track reference exists.
Visual truth: handoff README §Screens + renders 01/02/03/05/06/10 + HTML sections. Divergences per spec (multi-active rows; truthful footer copy; "grew" meta; Skip/Remove/Find-it only).

- [ ] 1. `QueueViewStateTests`: state selection (empty/ready/working/finished derivation), drop accepted in every state, Return on focused row invokes onOpen. FAIL → implement → PASS.
- [ ] 2. Build each view against renders (entrance animations; Reduce Motion variants; VoiceOver labels on status column; active rows render `rowETASeconds` as "Ns left", finished rows render `rowDuration` in the meta). One commit per view file.
- [ ] 3. A11y step: context menu present on every row (the gear's non-hover path); VoiceOver label audit over chips/status/gear/capsule (assert `accessibilityLabel` presence in state tests where the API allows), Reduce Motion paths compile-checked via previews. Commit.

### Task P-B: Popovers + sheets — Sonnet, track B (worktree `…-b`)

**Files:** Create `Sources/Toolbox/Queue/QualityPopover.swift`, `OCRPopover.swift`, `PerFileSettingsPopover.swift`, `VersionsPopoverContent.swift` (NEW file — the old `Compress/VersionsPopover.swift` is left COMPLETELY untouched; its live consumer `CompressView` survives until I1b, so an in-place rewrite would break this track's own build), `ChangeQualitySheet.swift`, `ScanConsentSheet.swift`, `RecentBatchesSheet.swift`; modify `Sources/Toolbox/App/AboutView.swift` (redesign per screen 11 — init STAYS no-arg `AboutView()` (SidebarView still calls it until I1b); **PRESERVE the three `.focusEffectDisabled()` modifiers**, the About-sheet net of the stray-focus-ring invariant). Test: `Tests/ToolboxTests/PopoverLogicTests.swift` (new).

**Interfaces — Consumes (read-only, plus the ONE mutating call):** `QueueViewModel` surface incl. `useCard(_:for:)` — each `cards` row's tap calls `model.useCard(card.key, for: job)`, the in-use row is inert (`PopoverLogicTests` leg asserts the wiring) — `RowVersions.cards`/`searchableByCard` (F1b), `HistoryStore.groupedByDay`, `measuredPageRate` (F5c), `QueueComponents` (complete inventory — a missing component is a stop-and-report). **Produces (exact inits P-A's seam receives):** `QualityPopover(model:)`, `OCRPopover(model:)`, `PerFileSettingsPopover(model:jobID:)`, `VersionsPopoverContent(model:jobID:)`, `ChangeQualitySheet(model:)`, `ScanConsentSheet(model:jobID:)`, `RecentBatchesSheet(history:)` (holds it as `@ObservedObject` — same nested-observation rule as P-A), `AboutView()` (no-arg, frozen).

- [ ] 1. **Rebuild-toggle domain (spec §7's UI half — F2 owns only the engine half)**: the Rebuild-the-scan toggle is HIDDEN on non-`.scanColour` rows and DISABLED with the explanatory caption at `.maximumQuality` — `PopoverLogicTests` leg asserts both states (an always-enabled toggle whose flip changes nothing is the inert control the spec forbids). **Searchability subtitles (spec §6.4's honest-label requirement terminates HERE)** — composition rule: the design's fixed subtitle DROPS ITS TERMINAL FULL STOP and appends the claim with the handoff's own separator register — composed strings pinned exactly: `"Never modified, still in its folder · Searchable"` / `"… · Not searchable"` (entry false) — asserted verbatim in the tests; no entry → the design copy untouched, stop and all (OCR never ran). Both strings are recorded divergences (owner: P-B — registered in Global Constraints). `PopoverLogicTests`: subtitle composition (searchable / not-searchable / no-label-when-OCR-off), quality totals per preset from analyses; per-file estimate reflects overrides; change-quality deltas from current rows; duration lines only when `measuredPageRate` non-nil; consent honest copy for `.original` kind; `testCompareVersionsPairSelection` (see step 2). FAIL → implement → PASS.
- [ ] 2. **Compare versions…** (handoff screen 07 footer, spec §7 — the ONLY comparison affordance; D8's in-app comparator stays rejected): full-width secondary button; PAIR = the in-use version + the currently highlighted row (highlight on the in-use row → in-use + first parked); opens both via `NSWorkspace.shared.open` (the existing open pattern — Preview handles PDFs); DISABLED when the row has only one file. Logic test `testCompareVersionsPairSelection` covers all three highlight cases + the disabled state. NOTE: the redesign has NO Quick-Look surface — `quickLookURL`/`frozenQuickLookItems`/`freezeQuickLookItems`/`.quickLookPreview` all live in `CompressView.swift` and retire with it at I1b; none is needed here.
- [ ] 3. One commit per view. A11y: labels for radio/toggle/check rows; Reduce Motion on sheet/popover motion.

### Task P-C: Self-updater — Opus, track C (worktree `…-c`)

**Files:** Create `Sources/Toolbox/App/SelfUpdater.swift`, `Sources/Toolbox/App/UpdateBannerView.swift` (NOT `UpdateBanner` — `RootView.swift` holds a file-private incumbent of that name; a same-named module-level type is an invalid redeclaration, `swiftc`-verified; I1a deletes the incumbent, its call site, and its now-lying doc comment when it rewrites RootView). Modify `Sources/Toolbox/App/UpdateChecker.swift`. Test: `Tests/ToolboxTests/SelfUpdaterTests.swift` (new, fixture-served).

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
    init(isBusy: @escaping () -> Bool,                    // I1 wires to { model.isRunning }
         sessionConfiguration: URLSessionConfiguration = .ephemeral,   // updater BUILDS its session with self as delegate
         bundleURL: URL = Bundle.main.bundleURL)
    // LIFETIME (I1a): held as `@StateObject` in RootView — constructible BEFORE any release arrives
    // (UpdateChecker.available is nil until check() completes), so the release is a call argument,
    // never init state; the object is created once and never rebuilt on re-render (published phase survives).
    static func installDestination(for bundleURL: URL) -> URL?   // writable …/Applications parent, else nil
    func update(release: UpdateChecker.Release) async     // isBusy() → .blockedByRun, no side effects
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
- [ ] 2. **Banner dismissal (spec §7/§10)**: × dismiss persists PER VERSION. Produces (added to the block above) — BOTH readers pinned to one key so the × invalidates the view (a static UserDefaults read registers no SwiftUI dependency; the wrapper is the invalidation source):
```swift
struct UpdateBannerView: View {
    private static let dismissKey = "bannerDismissed"
    @AppStorage(dismissKey) private var dismissedVersion: String = ""
    init(release: UpdateChecker.Release, updater: SelfUpdater, store: UserDefaults = .standard) {
        …; _dismissedVersion = AppStorage(wrappedValue: "", Self.dismissKey, store: store)
    }
    static func isDismissed(version: String, in store: UserDefaults) -> Bool  // test seam, same key + store
}
```
body renders nothing when `dismissedVersion == release.version`; the × sets `dismissedVersion = release.version` (wrapper write → view invalidates → banner hides immediately); re-shows for a newer version. Tests `testBannerDismissalPersistsPerVersion` + `testNewerVersionReShowsBanner` drive the predicate through a per-test suite with teardown — `let suite = "toolbox.tests.\(UUID().uuidString)"; let store = try XCTUnwrap(UserDefaults(suiteName: suite))` (the initialiser is failable) + `addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }` so no state leaks across runs. I1a mounts the view.
- [ ] 3. Commits: `feat(update): release asset parsing`, `feat(update): self-updater state machine`, `feat(update): banner view` (banner shows `blockedByRun` as disabled button + caption "after the current batch finishes").

### Task P-D: R-net test re-derivation — Opus, track D (worktree `…-d`)

**Files:** Modify `Tests/ToolboxTests/QueueViewModelTests.swift`, `Fixtures.swift`, `TestSupport.swift` (**ADDITIVE ONLY** — no signature change to the shared doubles or `Gate`: three sibling tracks compile against them in concurrent worktrees; a needed change is a stop-and-report), `ToolQueueTests.swift`, `VersionStoreTests.swift`, `RunnerUpStoreTests.swift` as consequences demand. No `Sources/` edits — a needed VM change is a stop-and-report.

Protocol (spec §11, widened): enumerate all **62** existing `QueueViewModelTests` funcs + the untagged early block, AND every test in ANY suite whose asserted behaviour this spec reverses — located by grepping the MECHANISM'S SYMBOLS (`runTask == nil`, `isRunning`, `alternateOutput`), never rule tags alone; each gets **adapt** / **superseded-by(name)** / **new sibling**. Already-owned flips stay with their owners (F2 owns all eight alternate-asserting `CompressEngineMRCTests` dispositions; F4 owns the two add-guard flips) — P-D verifies those dispositions landed and enumerates the rest. R19's reversal likewise. Enumeration table as a file comment atop the class; version-cap collision (consent loser + previous park) asserted if not already in F1b.

- [ ] 1. Commit the enumeration table (`test(queue): R-net re-derivation map`), then work MARK-group by group, suite green after each, one commit per group.

### Task P-E: DESIGN.md rewrite — Sonnet, track E (worktree `…-e`)

**Files:** `DESIGN.md` ONLY. Rewrite as the app's visual law from the handoff (tokens light+dark, typography, spacing/radii/shadows, motion, component inventory, per-screen structure, copy register). **Preserve a Focus (Accessibility) section with the 2px accent outline requirement** (stray-focus-ring invariant anchor). Numbered sections with a header index so I2 re-anchors deterministically.

- [ ] 1. Rewrite; token-for-token self-check against handoff README; commit `docs(design): rewrite DESIGN.md to unified-queue redesign`.

---

## Phase I — serial integration (LCW worktree, after all tracks merge)

### Task I1a: Wire the shell — Opus

**Files:** Modify `Sources/Toolbox/App/RootView.swift` (single pane: mount `QueueView`, plugging P-B's views into ALL NINE frozen seam slots — quality/ocrOptions/perFile/versions/changeQuality/scanConsent/recentBatches/about + the `showAbout` binding; `SelfUpdater` wired with `isBusy: { model.isRunning }`; `UpdateBannerView(release:updater:)` mounted above the queue content (the file-private incumbent `UpdateBanner` struct, its call site and its stale never-self-updates doc comment DELETED in this rewrite), sliding per the handoff's banner motion; `SelfUpdater` lifetime wired EXACTLY thus (the naive property-initialiser closure over a sibling property does not compile, and the cheapest escape — `isBusy: { false }` — would silently kill spec §6.10's busy block):
```swift
init(showAbout: Binding<Bool>) {
    _showAbout = showAbout
    let m = QueueViewModel()
    _model   = StateObject(wrappedValue: m)
    _updater = StateObject(wrappedValue: SelfUpdater(isBusy: { m.isRunning }))
}
```
`showAbout` is the `@State` hoisted to `ToolboxApp`, passed down and handed to `QueueView`'s ninth seam slot — ONE presentation state, three togglers (⋯ item, app menu, ×), one sheet; window-level drop), `ToolboxApp.swift` (app-menu About via `CommandGroup(replacing: .appInfo)` toggling an `@State` hoisted to `ToolboxApp` and passed into `RootView` — ONE presentation state shared with the `⋯` menu item, so the two entry points cannot both present), `WindowConfigurator.swift` (min 900×640 — **PRESERVE `installStrayFocusClear(on:)` + `installArmingObserver()` untouched**, the window net of the stray-focus-ring invariant) — the LOAD-BEARING site first (`.frame(minWidth:minHeight:)` constrains CONTENT, not the window — `WindowConfigurator.swift`'s own doc comment): `RootView.swift`'s `.onAppear { WindowSetup.applyMinimumSize(NSSize(width: 820, height: 560)) }` → `(width: 900, height: 640)` — the only code that assigns `window.minSize`; plus `RootView.swift`'s `.frame(minWidth: 820, minHeight: 560)` → `(900, 640)`, `ToolboxApp.swift`'s `.frame` likewise and `.defaultSize(width: 900, height: 600)` → `(900, 640)`; `WindowSetup.preferredSize` already matches. Run `xcodegen`.

- [ ] 1. Wire, build, full suite PASS. Commit: `feat(app): single-window unified-queue shell`.

### Task I1b: Delete legacy + orphan sweep — Sonnet

**Files:** Delete `App/SidebarView.swift`, `App/Tool.swift`, `Compress/CompressView.swift`, `Compress/VersionsPopover.swift` (superseded by P-B's `VersionsPopoverContent`; its sole consumer `CompressView` dies in this same task), `OCR/OCRView.swift`, `OCR/OCRViewModel.swift`, `Tests/ToolboxTests/OCRViewModelTests.swift` (its cancel invariant lives on as `QueuePassTests.testCancelStopsQueue`), `Tests/ToolboxTests/BatchProgressTextTests.swift` (subject deleted). Modify `Tests/ToolboxTests/SmokeTests.swift`: its single test asserts `Tool.allCases` — the hosted-target wiring canary is RE-TARGETED onto a surviving symbol (`XCTAssertEqual(CompressPreset.allCases.count, 3)`), never deleted (the canary's purpose survives the enum it happened to use). From `Components.swift`: `FileRow`, `DropZone`, `ToolHeader`, `SegmentedPreset`, `SegmentedPresetOption`, `SuccessBanner`, `ToolIconTile`, `Card`, `LinearProgress`, `batchProgressText` — then a zero-consumer sweep over ALL of `Components.swift` (grep each remaining symbol; delete any orphan). `xcodegen`.

- [ ] 1. Grep-verify zero consumers per deletion first; delete; build; full suite PASS. Commit: `chore(app): delete sidebar and legacy tool views`.

### Task I2: Docs, citations, DECISIONS, smoke, focus test — Sonnet

- [ ] 1. Citation sweep: `rg -n "DESIGN\.md"` repo-wide outside `.claude/` — RE-DERIVE the count at sweep time (tracks added files and I1b deleted `Tool.swift` since the last count; the checkable gate is ZERO stale references, not a number); re-anchor every reference in `Sources/` + `scripts/`; `CODE_GUIDELINES.md` is a HUMAN doc — read-only, and none of its mentions is a `§N` citation, so no edit needed. Commit.
- [ ] 2. `UpdateChecker`/`SelfUpdater` doc comments + `.claude/OVERVIEW.md` boundary table: user-initiated download path. `DECISIONS.md` entries: self-update posture reversal; MRC R7 asymmetry removal; deferral fulfilments (combined pass, per-file overrides, drag-during-run, history). Cite `**Spec:** .claude/specs/20260730-ui-redesign.md`. Commit.
- [ ] 3. `CompressSmoke`: compound-shape assertion (`outcome.compress` non-nil, `after < before`). Commit.
- [ ] 4. Focus-ring net check: add `WindowSetupFocusTests` asserting the arming observer installs and a `.plain`-styled probe control carries `clearsClickFocus` behaviour at the mechanism level; the BEHAVIOURAL check (popover-close keyboard walk) is V1's protocol — spec §9's "regression test stays green" is satisfied by this pair. Commit.

### Task I3: Gates + integration — Sonnet

- [ ] 1. All SEVEN `GATES.md` gates: `project-generates`, `ghostscript-builds`, `ghostscript-self-contained`, build, `tests` (mandated-by-human), `packaged-app-compresses`, `no-personal-corpus-references`. Green or stop-red.
- [ ] 2. Fixture-server updater functional pass (spec §11): build installed into `~/Applications`, one real update, old instance exits, new version relaunches.

### Task V1: Visual verification — orchestrator-owned, bounded

Owner: the LCW orchestrator (not a track). Protocol: build, drive with computer-use, capture all 14 screens light + dark, side-by-side against `renders/screen-*.png`; include the stray-focus-ring keyboard walk (open/close every popover and sheet via keyboard, no blue ring residue). Archive each screen's comparison pair under `$(git rev-parse --path-format=absolute --git-common-dir)/lcw/20260730-ui-redesign/visual/` (spec §11's archive requirement). Budget: up to THREE fix-and-recompare iterations per screen; a screen still divergent after three → stop-red to the human with the comparison pair. Then the private-corpus functional pass (spec §11), then review-team gate → PR.

---

## Self-review notes

- Spec coverage re-walked after revision: §6.1→F4, §6.2→F5a, §6.3→F1, §6.4→F3+F5a+F1b, §6.5→F4+F5a, §6.6→F4, §6.7→F5d, §6.8→F5c+F5a(semaphore), §6.9→F6, §6.10→P-C(+I1a busy-wire, I3 functional), §6.11→I1b, §7 screens→P-A/P-B+F5b(consent)+F5e(re-runs re-apply OCR), §8→F7/P-E/I2, §9→F7+P-A/P-B a11y steps+I2 step 4+V1, §11→P-D/I3/V1, §13 acceptance 1→V1 (owner + budget).
- Type-consistency pass: `RowProblem` defined in F1 (Models) and consumed by F4's `RowInspection` and F1's `CompressOutcome.skipped`; `OCRing`/`StubOCREngine` defined F3/F4 before F5a consumes; seam signatures in P-A's Produces match P-B's Produces one-for-one (nine slots — eight content closures + the About binding, `(ToolJob.ID) -> AnyView` where a row id is needed); `measuredPageRate` produced F5c, consumed P-B; `rowETASeconds`/`rowDuration` produced F5c, consumed P-A (screen 05's "8s left" + "finished in 12 seconds").
- Topological order: F1→F1b→F2→F3→F4→F5a→F5b→F5c→F5d→F5e→F6→F7 all serial; every P-track consumes only F-phase symbols; I1a consumes P-A+P-B+P-C merges.
- File-list completeness derived by grep (F1's ~82 test sites; I1b's orphan list), not recall.

## Gate rounds

- **Certify 8 (full read, Opus): SHIP** — no critical/major; six one-clause minors, all fixed (`.shipped` no-op completes useCard's four-key partition; useCard wired to P-B's radio rows with a test leg; the shipped-is-original gate moved into F1b's cards code with a direct-construction test; the ghost sum-test name redirected to its real F5c/F6 assertions; the worktree bootstrap fallback changed from symlink to copy — the directory-scoped ignore rule does not match a symlink and a track's add -A would commit it; the rebuild-toggle's UI half owned by P-B with hidden/disabled assertions). PLAN GATE CLOSED. Lesson-candidates: enum-keyed entry points partition every case in one sentence; produced affordances name their consumer in the consuming track's list; a gitignore trailing slash is a file-type claim; spec pins split across engine and UI halves need both halves assigned.
- **Certify 7 (full read, Opus): NO-SHIP** — 1 critical (certify-6's "guards for EVERY key" made delegated `.runnerUp`/`.previous` switches silent no-ops — `useVersion` self-guards AND self-inserts, so re-taking the guard trips it; branch-split pinned with the delegation test) + 2 majors (eight ship-blocker tests were prose-only behind a false "(in the step-1 manifest)" claim — all folded, claim deleted; the failure disposition still described the removed park-then-copy — rewritten promote-shaped with re-targeted tests) + 1 minor (symlink depth measured at four levels; build script promoted to primary route). Lesson-candidates: a mechanism rewrite re-sweeps every sentence and test name written for the old mechanism (third consecutive round of this class); delegating to a guarded method inherits its guard — never re-takes it; location-asserting parentheticals are checkable claims — grep them in the writing commit.
- **Certify 6 (full read, Opus): NO-SHIP** — 4 majors (the `?? false` default manufactured a searchability claim on compress-only rows against §6.4 — flag permutation now conditional on a non-empty map; the bespoke park-then-copy destroyed the displaced previous before the copy was attempted — re-routed through the repo's existing `promote` primitive with `shippedStranded`'s failure path; `useCard` lacked `useVersion`'s two synchronous-prefix guards — an in-flight double-click interleaved destructive sequences; NO WORKTREE COULD BUILD — `Resources/ghostscript` is gitignored and absent from fresh worktrees, `project.yml` errors on the missing path — bootstrap line added for all six worktrees) + 1 minor (the token identifier mapping extended to Radius and Typography with P-E briefed). Lesson-candidates: re-run every new mutator against the EMPTY state of each map it writes; committed-state no-ops are not re-entrancy guards; grep for the existing primitive before pinning a bespoke file-swap; forked worktrees inherit the repo's IGNORED build prerequisites — name the bootstrap; token-mapping fixes apply to every namespace.
- **Certify 5 (full read, Opus): NO-SHIP** — 3 majors, all on the `.originalReference` surface and byte accounting (`useCard` never permuted `searchableByCard` — flag-move rule added; the reference row wasn't gated on shipped-is-original — duplicate row + destructive second click fixed with gate + no-op + pinned synthesised FileVersion; only the delivered file was re-stat'd post-append — per-artefact re-stat with `RetainedVariant.bytes` widened to var) + 4 minors (alternateURL attachment predicate pinned to `runnerUp != nil`; composed subtitle strings pinned verbatim with the handoff's separator register; the all-OCR footer's never-"0 MB saved" rule owned by P-A with a test; handoff token names mapped onto existing identifiers — no rename sweep). Lesson-candidates: a new mutator inherits every invariant its sibling was fixed to honour; presence rules re-derive over every location the affordance moves the value into; repeatable destructive affordances specify their second invocation; re-stat obligations are per-artefact; handoff token lists are identifier declarations — diff against the repo before pinning.
- **Certify 4 (full read, Opus): NO-SHIP** — 5 majors (RowOutcome had dropped the shipped `EngineVariant` fact with the bridge instruction inverting the runner-up's kind on every heavy row → `shippedVariant` field + corrected bridge + single inversion rule; the R7 retention could park an unvalidated hybrid — `validatesOffPool` pinned to the fall-through branch + discriminating test; the F7 inventory was assembled from memory, missing the badge, the valued popover row and the variant-preview card → step-0 per-screen derivation + three components; `.originalReference`'s park had no named slot → `.previous`, replacing the occupant per R12/R14's standing rule; the searchability subtitle chain terminated in nothing → P-B composition rule + two recorded divergence strings + assertions) + 1 minor (row context menu owned in F7/P-A). Lesson-candidates: complete-inventory claims derive from the visual source screen-by-screen; deleting an enum case deletes every fact it encoded — grep the fact's readers; a spec adjective ("valid") must name the call that establishes it; a state mutator names its destination; producer chains terminate in a rendered string with an owner and an assertion.

- **Certify 3 (full read, Opus): NO-SHIP** — 4 majors, each compiling clean while shipping a wrong number, wrong capsule, false label or inert affordance (two more grep-derived batch-preset sites incl. the R16 provenance WRITE that would defeat the re-point from the other side; the capsule gate re-pinned on parked-version-exists — count>1 drew a capsule on every delivered row against renders 06/07; the re-run append flag pinned to THIS run's result with the failed-append test; rebind's full state-reset surface) + 4 minors (noGain tooFaint test; ghost test name deleted; TestSupport additive-only across concurrent tracks; rowETASeconds/rowDuration consumers named). Lesson-candidates: an always-present derived row re-opens count-derived GATES, not just strings (recurrence — promote); row-scoping enumerations grep provenance writes too; a fix affordance pins its full state-reset surface; "inherits every obligation" is read as its enumeration — restate ship-blocker invariants explicitly.
- **R11 (incremental, Opus): NO-SHIP** — 2 majors (window minimum was pinned at three sites that cannot set it — the only `window.minSize` assigner, RootView's `applyMinimumSize`, was unnamed; estimator eligibility input had no callable entry, no owned call site, no cache invalidation) + 4 minors (RecognisedDocument.outcome named symbol + pageCount; F5e in ordering/coverage lines; rowDuration accessor; footer). Lesson-candidates: "pinned at all N sites" must name the site that assigns the value — grep the mechanism, not the token; adding an input to a cached value re-opens its invalidation; obligations only assign to tasks that run later; exclusivity-clause rules ship named symbols.
- **Certify 2 (full read, Opus): NO-SHIP** — 1 critical (the two non-batch `engine.compress` call sites — recompress + rerunForSwitch — were unowned, carrying three spec obligations: re-runs re-apply OCR, opt-outs survive re-runs, descriptor-kind variant mapping → new Task F5e) + 5 majors (swapShipped never permuted `searchableByCard` — false label on every instant switch; `.tooFaint` had no producer — F3 pins the RecognisedDocument→OCROutcome partition, real-engine-tested, F1's bridge corrected; F5d's calibration ignored the rebuild opt-out — eligibility input added; per-row ETA/duration surfaces missing + the 10% gate was per-batch not per-leg; HistoryStore had no test seam — directory override + VM param, hermetic tests) + 6 minors (armedExclusions published + setter; @ObservedObject pinned for nested history observation; curated language list homed in F3; Finished-header rendering split; window minimum pinned at all three sites; I2's count re-derived at sweep time). Lesson-candidates: a task changing an engine contract owns EVERY call site; slot-state maps must be permuted by every slot mutator; a criterion-defined enum case needs a producer tested against the real engine; recalibration re-opens every input that changes the prediction; VM-constructed stores need the repo's existing test-seam pattern; handoff per-row values are data requirements, not visuals.
- **Certify 1 (full read, Opus): NO-SHIP** — 4 cross-task majors only a full read exposes (F2's pinned engine signature returned the queue wrapper `JobResult` instead of `RowOutcome`, contradicting F1; deleting `Tool.swift` broke `SmokeTests`' canary with no disposition — re-targeted onto `CompressPreset.allCases`; spec §6.1's row-scoping of preset-keyed state had no owning task — F4 step 5 added with re-key + consumer re-pointing + tests; `HistoryStore` had no declared owner or observation surface — VM-owned single instance, ObservableObject, published fields, I1a wiring pinned) + 5 minors (paired `capsuleTitle` re-baseline; Skip/subset-re-run VM surface declared; V1 archive step; `QueueRow` problem variant; `batchProgress` post-run persistence + test). Lesson-candidates: certify diffs every pinned signature against the repo declaration; a deletion's blast radius is a repo-wide symbol grep; "every X gains Y" needs an owner and a test per X; cross-track objects need a named owner AND observation surface; distinguish gaps the track boundary catches from gaps that compile silently wrong.
- **R10 (incremental, Opus): SHIP** — R9's ninth-slot major + suite-identifier minor resolved (SDK-verified CommandGroup placement; dismissal × works via the sheet's environment dismiss, keeping AboutView's no-arg init honest); one minor: this footer backfilled. Lesson-candidates: a presentation state with two entry points is a seam slot; grep numeral AND spelled-out forms when renumbering; write each round's footer line in the same commit as its fixes.
- **R9 (incremental, Opus): NO-SHIP** — 1 major (I1a's pinned zero-arg init could not receive the About state; frozen seam had no binding → the compiling escape was the double-presentation spec §7 forbids — ninth slot `showAbout: Binding<Bool>` added, init(showAbout:) shown) + 1 minor (unbound `suite` identifier in the test snippet). Lesson-candidates: a test-only seam mirroring production logic proves the seam, not the feature; pinning an initialiser body pins its parameter list; frozen seams must carry presentation state, not just content.
- **R8 (incremental, Opus): NO-SHIP** — 2 majors (the testability refactor had removed the banner's only SwiftUI invalidation source — × would render dead; the @StateObject + isBusy prose wiring didn't compile and its cheapest escape silently killed the busy block — both fixed with compile-probed code blocks) + 1 minor (per-test UserDefaults suite + teardown). Lesson-candidates: replacing a property wrapper with a method for testability removes the view's invalidation source — re-check; a lifetime pin must show the constructing code; probe compile claims under the project's own language mode.
- **R7 (incremental, Opus): NO-SHIP** — 1 critical (P-C's `UpdateBanner` collided with RootView's file-private incumbent — swiftc-verified invalid redeclaration; renamed `UpdateBannerView`, incumbent + call site + lying doc comment deleted at I1a) + 3 majors (SelfUpdater lifetime unowned; dismissal predicate untestable as private view state; two prose-only tests dropped from F5a's manifest — a recurrence of R5's own fixed class) + 1 minor (P-D's stale "trio"). Lesson-candidates: a new top-level type name is a repo-wide grep incl. file-private declarations; naming the mount is not naming the owner; private view state cannot satisfy an ordered test; re-run the previous round's check against the new text.
- **R6 (incremental, Opus): NO-SHIP** — 1 critical (the withhold rule as written deleted the untouched-original park — breaking a green test F2 ordered to pass and reversing DECISIONS 2026-07-24 by silence; scoped to compress variants verbatim §6.3) + 4 majors (eight grep-derived MRC dispositions replacing a recalled "three"; recognise-failure-on-delivered-path disposition + isDegraded .failed clause; testIsDegradedPartition in the owning task; UpdateBanner Produces claim was false and the banner had no mount) + 5 minors. Lesson-candidates: a new step's blast radius includes the pre-existing text it collides with; byte-predicates must name their artefact domain; "declared in Produces" is a checkable claim; enumerate sweeps by grep output, not spec paraphrase; a new computed property needs a test in its defining task.
- **R5 (incremental, Opus): NO-SHIP** — 1 critical (the spec's R7-asymmetry reversal had NO implementing task while the plan ordered its contradicting MRC-suite test to stay green — engine retention change + three test dispositions now in F2, consent-fires-regardless VM test in F5b) + 8 majors (F4 owns the two add-guard flips + its full file list; P-D's protocol widened to mechanism-symbol greps with flips staying with their owners; nine prose-only test names folded into F5a's manifest; rescue-leg .alreadySearchable/.tooFaint dispositions added; savings-sum exclusion restated in F5c/F6/P-A with the two sum tests moved where the sums exist; three missing ledger-invalidation legs added to F4; bannerDismissed per-version persistence given to P-C; warn/degraded classification defined — RowOutcome.isDegraded + StatusIndicator.Kind.warn) + 9 minors (run-guard-survives note, two updater fixture legs, batch verb floor test, Clear release + re-add test, engine-return→commit cancel test, banked-cancel history test, consent-undo assertion, divergence list completed with owners, BatchProgressTextTests dispositions re-homed to F5c). Lesson-candidates: map every spec change-table row to an owning task; a task's step manifest is the executable instruction — prose-only test names are dropped tests; a guard-relaxing foundation task owns every test of that guard; aggregate rules restate in every task computing the aggregate; sweep plans against spec §7/§10 state inventories, not §11 alone.
- **R4 (incremental, Opus): NO-SHIP** — 4 majors (legacy `VersionsPopover` shim added to F1b with `.originalReference` filtered; §6.4 `.alreadySearchable` labelling + §6.5 contingency suffix RAISED AS SPEC ESCAPES to the human — plan may not amend the spec by fiat, both marked PENDING with F5a blocked on them; freeze-port step deleted as unbased — the pattern lives in `CompressView.swift` and the redesigned popover has no Quick-Look surface; "Compare versions…" given an owner, pair rule, disabled state and test in P-B) + 6 minors (Consumes rename, `compressFailed` single-attribution to F1 + inspection-ignores clause, `reserveDelivery`/`releaseDelivery` declared in F4's Produces, divergence framing corrected, capsule `count > 1` gate pinned with F7 as enforcer, `useCard(.originalReference)` failure disposition + test). Lesson-candidates: a reviewer's prior request is not authority — re-derive from the design source; tuple label changes are API breaks — sweep every `.<label>` consumer; a plan that finds the spec wrong reports, never refines; every visible design element needs a named owner; always-present rows re-open every count-derived string and gate.
- **R3 (incremental, Opus): NO-SHIP** — 4 majors (F1b assertion accounting corrected to eight + arity re-baseline moved to F5a; two superseded capsule-label tests re-targeted with recorded handoff authority; `searchableBySlot` key space → `VersionCardKey` display identity incl. `originalReference` + `useCard` semantics; contingency `-ocr` name now reserved through the main-actor ledger mid-run, one-name-per-job preserved) + 9 minors (eight-slot residues, async redirect delegate variant + cancel semantics, continuation copy recorded as divergence + `RowProblem.compressFailed`, error-taxonomy default clause, `.alreadySearchable` honesty clause, app-menu About mechanism, dead citations re-anchored at F1b, `searchableByCard` default, freeze-pattern port step + test, this footer added). Lesson-candidates: per-assertion task attribution in re-baselines; count render rows against key spaces; contingency paths name their reserving task; adopted copy can retire prior invariants — state the outcome; delegate signatures must compile with their prescribed body.
- **R2 (incremental, Opus): NO-SHIP** — all 24 R1 findings confirmed fixed; 4 new majors (unproduced `searchableBySlot`/`originalURL`; F1b breakage outside its file list; in-place `VersionsPopover` rewrite with live out-of-track consumer; missing About seam slot / doubly-assigned `⋯` menu) + 7 minors, all applied.
- **R1 (full read, Opus): NO-SHIP** — 14 majors (track-boundary break on `VersionStore`; unfrozen P-A↔P-B seam; understated file lists; dropped spec cases; `finalBytes` ownership; missing doubles + OCR seam; incomplete F7 inventory; stale/wide updater host pin — live-probed; missing update-during-run gate; half-done estimator calibration; oversized F5/I1; unprotected focus-ring nets; unowned visual verification) + 10 minors, all applied.
