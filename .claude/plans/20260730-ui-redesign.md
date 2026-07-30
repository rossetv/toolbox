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
- All numbers in UI `.monospacedDigit()`. Copy verbatim from the handoff except spec-recorded divergences (§6.3 "grew", §6.8 footer line, honest variant labels, §7 consent copy).
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
enum RowProblem: Equatable { case locked; case missing; case unreadable }   // defined HERE (F4's inspection reuses it)
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
    case tooFaint                                // ran, recognised nothing usable
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
}
enum JobState: Equatable { case queued; case analysing; case running(Double); case done(RowOutcome); case failed(String) }
```
`JobResult` becomes `{ outcome: RowOutcome, outputURL: URL?, alternateURL: URL?, mrcReport: MRCDocumentReport? }` (same field names, `outcome` re-typed). The old `compressedHeavy` case is GONE — its information lives in `runnerUp` (kind `.mrc` when the parked loser is the hybrid, `.plain` when it is the gs output, `.original` when it is the untouched input).

**Steps:**
- [ ] 1. Write `RowOutcomeTests`: `testGrewIsDerivedFromFinalBytes`, `testRunnerUpDescriptorIndependentOfWinner` (`runnerUp: .init(kind: .mrc,…)` AND `.init(kind: .plain,…)` both construct — gs-won retention representable), `testSkippedProblemCase`, `testCancelledOCRDistinctFromNil`, `testEquatable`. Run: expect FAIL (types missing).
- [ ] 2. Implement; delete `JobOutcome`; bridge every switch/return site with equivalent behaviour: old `.compressed(b,a)` → `RowOutcome(originalBytes: b, finalBytes: a, compress: .compressed(before: b, after: a))`; old `.compressedHeavy(b,a,r)` → same + `runnerUp: .init(kind: .mrc, bytes: r, searchable: false)`; old `.ocrAdded(p,s)` → `RowOutcome(originalBytes: n, finalBytes: n, ocr: .added(pages: p, skipped: s))`; old `.alreadySearchable`/`.noGain` likewise.
- [ ] 3. Build: expect compile FAILURES at exactly the enumerated sites; fix each mechanically; iterate to green. Then full suite: PASS (behaviour-preserving).
- [ ] 4. Commit: `refactor(models): replace JobOutcome enum with compound RowOutcome`.

### Task F1b: VersionStore four-row surface + honest labels — Opus, foundation

**Files:**
- Modify: `Sources/Toolbox/Compress/VersionStore.swift` (`RowVersions.cards`, `capsuleTitle`, new mutators; `VersionSlot` widens `Equatable` → `Hashable` — dictionary key)
- Modify: `Tests/ToolboxTests/VersionStoreTests.swift` (extend) AND `Tests/ToolboxTests/CompressViewModelTests.swift` — ten existing assertions flip and are updated HERE (this is pre-fork foundation, not P-D's): the four `capsuleTitle` string asserts in `VersionStoreTests` (`"Heavy compression"`/`"Normal compression"`/`"Versions"` → the new `"N versions"` values, `count == 3` → new arity) and the five `capsuleTitle` + four `cards.first(where:)` sites in `CompressViewModelTests` (each updated to the new titles/arity, invariant unchanged).

**Interfaces — Produces (P-B consumes READ-ONLY; F5a is the PRODUCER of the new state):**
```swift
// RowVersions gains:
var originalURL: URL?                      // the untouched input, for the always-present Original reference row
var searchableBySlot: [VersionSlot?: Bool] // nil key = shipped. SEMANTICS: populated ONLY when the OCR leg ran
                                           // for this row; empty = OCR never ran → popover shows NO searchability
                                           // subtitles (design defaults stand). Never a lie in either direction.
// VersionStore gains the mutators F5a drives:
func setOriginalURL(_ url: URL, for id: ToolJob.ID)
func setSearchable(_ searchable: Bool, slot: VersionSlot?, for id: ToolJob.ID)
// cards emits up to FOUR rows in popover order: shipped, runnerUp, previous, original-reference
// (original-reference row appears when originalURL != nil AND no parked version already IS the original —
//  never two rows for the same file). capsuleTitle: "N versions" per handoff screen 06/07.
```
Parked cap stays structural (`runnerUp` + `previous` slots only — spec §5's ruling); the Original row is a reference, not a parked copy.

**Steps:**
- [ ] 1. Extend `VersionStoreTests`: `testCardsIncludeOriginalReference`, `testNoDuplicateRowWhenParkedVariantIsOriginal` (parked `.original` kind → 3 rows, not 4), `testSearchableBySlotEmptyMeansNoLabels`, `testSetSearchablePerSlot`, `testConsentRetentionPlusPreviousParkStaysWithinCap` (runner-up + previous occupied → cards = 4 incl. reference, never 5). FAIL → implement → PASS.
- [ ] 2. Update the ten flipped assertions in both test files to the new titles/arity. Full suite: PASS.
- [ ] 3. Commit: `feat(versions): four-row card surface with honest searchability`.

### Task F2: Engine per-file rebuild override + withhold-at-≥input — Opus, foundation

**Files:**
- Modify: `Sources/Toolbox/Compress/CompressEngine.swift`
- Modify: `Sources/Toolbox/Compress/CompressViewModel.swift` (`Compressing` protocol + call sites gain the param, pass `nil`)
- Test: `Tests/ToolboxTests/CompressEngineTests.swift` (extend)

**Interfaces — Produces:**
```swift
func compress(_ input: URL, preset: CompressPreset, to output: URL,
              alternateOutput: URL? = nil,
              rebuildScan: Bool? = nil,          // nil = derive as today; false = never MRC; true = MRC when ELIGIBLE
              mrcReport: ((MRCDocumentReport) -> Void)? = nil,
              progress: @escaping (Double) -> Void) async throws -> JobResult
```
Rules (spec §7 Per-file settings): `rebuildScan == true` never overrides classification eligibility (`.scanColour` only, complex-page rules stand — MRC R2); `preset == .maximumQuality` forces the MRC leg off regardless (MRC D3). Withhold rule: winner ≥ input → `.noGain` (as today); would-be runner-up ≥ input → no `alternateOutput` write, no descriptor. `finalBytes` in the returned outcome = compress artefact size (F1's ownership note — F5a re-stats after OCR).

**Steps:**
- [ ] 1. Extend `CompressEngineTests`: `testRebuildScanFalseSkipsMRCOnScanColour`, `testRebuildScanTrueDoesNotForceIneligible` (bornDigital + `true` → plain Rung-1), `testRebuildScanIgnoredAtMaximumQuality`, `testRunnerUpAtOrAboveInputWithheld` (verifier override forces a bloated variant → `runnerUp == nil`). Run: FAIL.
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
- Modify: `Tests/ToolboxTests/TestSupport.swift` (doubles lifted here), rename `CompressViewModelTests.swift` → `QueueViewModelTests.swift`
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
```
Reservation moves to `add(_:)` (delivered suffix per spec §6.5: compress-inclusive run → `-compressed.pdf`, OCR-only → `-ocr.pdf`; suffix re-reserved when the verb set changes while idle); release+re-reserve on destination/verb/override/rebind changes while idle; settings lock per run; mid-run adds reserve against locked settings. `ToolQueue.add` accepts during a run (launch loop re-polls queued jobs until drained). Inspection on add off-main (`OpenGuard.inspect` + `pageHasText` sample + estimator analysis); failures → `problem`, excluded from `canStart`.

**Steps:**
- [ ] 1. `git mv` + mechanical rename repo-wide. Full suite PASS. Commit: `refactor(queue): rename CompressViewModel to QueueViewModel`.
- [ ] 2. Lift doubles into `TestSupport.swift` (internal), re-derive width>1 arity, delete the three private duplicates; suite PASS. Commit: `test(support): shared width-aware engine doubles`.
- [ ] 3. Write `QueueAdmissionTests`: `testAddDuringRunJoinsBatch`, `testAddDuringRunReservesAgainstLockedSettings`, `testReservationReleasedOnRemove`, `testFolderChangeReReservesWhileIdle`, `testVerbSetChangeFlipsSuffix` (compress-on → `-compressed.pdf`; toggle to OCR-only while idle → re-reserved `-ocr.pdf`), `testOverrideVerbFloorBlocksLastVerbOff`, `testProblemRowExcludedFromCanStart`. Run: FAIL.
- [ ] 4. Implement part-1 surface. Run: PASS. Full suite: PASS.
- [ ] 5. Commit: `feat(queue): verbs, overrides, add-time inspection and reservation`.

### Task F5a: Single-pass job body — Opus, foundation

**Files:** Modify `Sources/Toolbox/Queue/QueueViewModel.swift`. Test: `Tests/ToolboxTests/QueuePassTests.swift` (new).

Job body per file (spec §6.2/§6.4/§6.5/§6.8): compress leg (when effective-on, per-row `preset`/`rebuildScan`) → cancellation check → OCR leg (when effective-on; width-2 semaphore; `recognise` from ORIGINAL, `append` to delivered file via temp + `replaceItemAt`, and to a retained runner-up variant file; `.original`-kind runner-up NEVER appended; append failure → `searchable = false`, never a job failure) → cancellation check → re-stat `finalBytes`, commit. Cancel between legs → `.ocr = .cancelled`, kept-and-banked.

**Producer duties pinned here**: the commit step populates F1b's new state — `setOriginalURL(job.url)`, then `setSearchable` per slot from the append results: shipped/parked = did its append succeed; `.original`-kind slot and the Original reference = `ocr == .alreadySearchable` (the input's own text state); no OCR leg ran → no `setSearchable` calls at all (empty map = no labels). **`CompressOutcome.skipped(problem:)` producer**: a compress-leg failure that is compress-specific (`CompressError.ghostscriptFailed`/`.validationFailed`) while OCR is effective-on does NOT fail the job — the body continues to the OCR leg against the ORIGINAL (delivering the `-ocr` name, reserved at add for this contingency), `compress = .skipped(problem: .unreadable)`, meta "Couldn't be compressed — made searchable instead". `CompressError.encrypted`/`.corrupt` fail the whole job (OCR would fail identically) → problem row.

- [ ] 1. Write `QueuePassTests`: `testCompressThenOCRSingleRow`, `testOCRAppliedToRunnerUpVariant` (both files carry layer, assert `pageHasText` each), `testOriginalVariantNeverAppended` (file untouched, `searchable == false`), `testSearchableBySlotReflectsAppendOutcomes` (incl. empty-map when OCR off), `testCompressFailureContinuesOCRLeg` (stub throws `ghostscriptFailed`; OCR on → `-ocr` output delivered, `compress == .skipped(problem: .unreadable)`), `testEncryptedFailsWholeJob`, `testCancelBetweenLegsBanksCompressed` (asserts `.ocr == .cancelled` + file kept), `testCancelStopsQueue` (successor to `OCRViewModelTests.testCancelStopsTheViewModelsQueue` — no further job starts after cancel), `testOCROnlyRowNoSizeLie`, `testOCRSemaphoreWidthTwo` (4 jobs, gated `StubOCREngine` → ≤2 concurrent in OCR leg), `testFinalBytesRestatedAfterAppend`. Run: FAIL.
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

- [ ] 1. Tests: `testConsentQueuedFIFOAndResolved`, `testConsentAppearsMidRun` (first consent surfaces while a later job still runs), `testRebuildWithoutAskingSkipsConsentAndKeepsRebuilt`, `testConsentKeepPhotographsSwapsInstantly`. FAIL → implement → PASS.
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

- [ ] 1. Tests: aggregation, nil-before-10%, monotonicity, per-leg labels, `measuredPageRate` recorded post-run. FAIL → implement → PASS. Commit: `feat(queue): batch progress and measured ETA`.

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
- [ ] 2. `QueuePassTests`: `testBatchEndRecordsHistory`, `testCancelledEmptyBatchRecordsNothing`. FAIL → wire → PASS.
- [ ] 3. Commit: `feat(history): recent-batches store with lifetime savings`.

### Task F7: Design system — tokens + full component inventory — Sonnet, foundation

**Files:** Modify `Sources/Toolbox/DesignSystem/Theme.swift`, `Components.swift` (restyle kept: `PrimaryButton`, `LinkButton`, `StatPill`, `PDFThumbnail`); create `Sources/Toolbox/DesignSystem/QueueComponents.swift`. Test: `Tests/ToolboxTests/ThemeTests.swift` (new).

Tokens (handoff README table, light+dark): `Theme.Colors` bg/surface/text/text2/text3/accent/link/success/warn/danger/stroke/sep/hairline/fill/track; `Theme.Radius` row 10, control 8, popover 12, sheet 14, capsule 980; `Theme.Motion` standard spring(0.35, 0.85), hover .15, press .12, popover .3, sheet .38, banner .45, checkPop .45; `Theme.Typography` adds windowHeadline/sheetTitle/rowName/bodyStrong/body13/meta/caption/sectionLabel.

`QueueComponents.swift` — the COMPLETE control inventory for all 14 screens (P-A/P-B create no components; a missing one is a stop-and-report, never an improvisation):
```swift
struct VerbChip: View { let title: String; let suffix: String?; let isOn: Bool; let icon: Image
                        let toggle: () -> Void; let openOptions: (() -> Void)? }   // two actions, two VoiceOver labels
struct StatusIndicator: View { enum Kind { case finished; case active(Double); case queued; case unchanged }; let kind: Kind }
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

**Files (create only):** `Sources/Toolbox/Queue/QueueView.swift`, `EmptyStateView.swift`, `DragOverlayView.swift`, `QueueHeaderView.swift`, `QueueRowsView.swift`, `QueueFooterView.swift`. Test: `Tests/ToolboxTests/QueueViewStateTests.swift` (new).

**Interfaces — Consumes:** `QueueViewModel` (F4/F5 surface), `HistoryStore` (F6), `QueueComponents` (F7), `FilePicker`, `RowVersions` read-only. **Produces — the FROZEN injection seam (I1 plugs P-B's views into exactly these seven slots; no other cross-track reference exists):**
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

**Interfaces — Consumes (read-only):** `QueueViewModel` surface, `RowVersions.cards`/`searchableBySlot` (F1b), `HistoryStore.groupedByDay`, `measuredPageRate` (F5c), `QueueComponents` (complete inventory — a missing component is a stop-and-report). **Produces (exact inits P-A's seam receives):** `QualityPopover(model:)`, `OCRPopover(model:)`, `PerFileSettingsPopover(model:jobID:)`, `VersionsPopoverContent(model:jobID:)` (adopts the old popover's Quick-Look freeze pattern — collection never shrinks while the panel is alive), `ChangeQualitySheet(model:)`, `ScanConsentSheet(model:jobID:)`, `RecentBatchesSheet(history:)`, `AboutView()` (no-arg, frozen).

- [ ] 1. `PopoverLogicTests`: quality totals per preset from analyses; per-file estimate reflects overrides; change-quality deltas from current rows; duration lines only when `measuredPageRate` non-nil; consent honest copy for `.original` kind. FAIL → implement → PASS.
- [ ] 2. One commit per view. A11y: labels for radio/toggle/check rows; Reduce Motion on sheet/popover motion.

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
    // Redirect policy (install.sh posture): follow hops; enforce https per hop via the delegate method,
    // declared NONISOLATED (it runs on the session's delegate queue; a @MainActor-isolated implementation
    // cannot satisfy the nonisolated protocol requirement and would race a security check):
    //   nonisolated func urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)
    // — non-https redirect → cancel + .failed (phase mutation hopped via await MainActor.run);
    // host-check the INITIAL URL only (parseRelease's pin). No redirect-host allow-list: probed 2026-07-30,
    // GitHub currently redirects to release-assets.githubusercontent.com and has changed this host before —
    // any list would be perishable.
}
```
Flow per spec §6.10: sha256 vs `<dmgURL>.sha256` → mount (plist-parsed) → payload+version check → strip quarantine on STAGED copy pre-swap iff `spctl` rejects (strip failure → abort pre-swap) → aside-swap (restore on failure; restore-failure → aside preserved + path in `.failed`) → detach best-effort → detached `/bin/sh` relaunch helper → terminate.

- [ ] 1. `SelfUpdaterTests` (fixture HTTP server + `hdiutil create` DMGs): checksum mismatch → `.failed`, no swap; mount failure; wrong payload version; `installDestination` nil → degrade; swap failure legs → working install remains, aside named on restore-failure; success path; `testUpdateRefusedWhileBusy` (`isBusy` true → `.blockedByRun`, filesystem untouched); `testNonHTTPSRedirectCancelled` (fixture redirect to `http://` → `.failed`). Never live GitHub. FAIL → implement → PASS.
- [ ] 2. Commits: `feat(update): release asset parsing`, `feat(update): self-updater state machine`, `feat(update): banner view` (banner shows `blockedByRun` as disabled button + caption "after the current batch finishes").

### Task P-D: R-net test re-derivation — Opus, track D (worktree `…-d`)

**Files:** Modify `Tests/ToolboxTests/QueueViewModelTests.swift`, `Fixtures.swift`, `TestSupport.swift`, `ToolQueueTests.swift`, `VersionStoreTests.swift`, `RunnerUpStoreTests.swift` as consequences demand. No `Sources/` edits — a needed VM change is a stop-and-report.

Protocol (spec §11): enumerate all **62** existing `QueueViewModelTests` funcs + the untagged early block; each gets **adapt** / **superseded-by(name)** / **new sibling**. R9's disable-during-run tests FLIP to assert admission; R19 likewise (reversals, spec §5). Enumeration table as a file comment atop the class; version-cap collision (consent loser + previous park) asserted if not already in F1b.

- [ ] 1. Commit the enumeration table (`test(queue): R-net re-derivation map`), then work MARK-group by group, suite green after each, one commit per group.

### Task P-E: DESIGN.md rewrite — Sonnet, track E (worktree `…-e`)

**Files:** `DESIGN.md` ONLY. Rewrite as the app's visual law from the handoff (tokens light+dark, typography, spacing/radii/shadows, motion, component inventory, per-screen structure, copy register). **Preserve a Focus (Accessibility) section with the 2px accent outline requirement** (stray-focus-ring invariant anchor). Numbered sections with a header index so I2 re-anchors deterministically.

- [ ] 1. Rewrite; token-for-token self-check against handoff README; commit `docs(design): rewrite DESIGN.md to unified-queue redesign`.

---

## Phase I — serial integration (LCW worktree, after all tracks merge)

### Task I1a: Wire the shell — Opus

**Files:** Modify `Sources/Toolbox/App/RootView.swift` (single pane: mount `QueueView`, plugging P-B's views into ALL EIGHT frozen seam slots — quality/ocrOptions/perFile/versions/changeQuality/scanConsent/recentBatches/about; `SelfUpdater` wired with `isBusy: { model.isRunning }`; window-level drop), `ToolboxApp.swift` (app-menu About → same `about` content), `WindowConfigurator.swift` (min 900×640 — **PRESERVE `installStrayFocusClear(on:)` + `installArmingObserver()` untouched**, the window net of the stray-focus-ring invariant). Run `xcodegen`.

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
- Type-consistency pass: `RowProblem` defined in F1 (Models) and consumed by F4's `RowInspection` and F1's `CompressOutcome.skipped`; `OCRing`/`StubOCREngine` defined F3/F4 before F5a consumes; seam signatures in P-A's Produces match P-B's Produces one-for-one (seven slots, `(ToolJob.ID) -> AnyView` where a row id is needed); `measuredPageRate` produced F5c, consumed P-B.
- Topological order: F1→F1b→F2→F3→F4→F5a→F5b→F5c→F5d→F6→F7 all serial; every P-track consumes only F-phase symbols; I1a consumes P-A+P-B+P-C merges.
- File-list completeness derived by grep (F1's ~82 test sites; I1b's orphan list), not recall.
