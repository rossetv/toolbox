# Toolbox UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task names its model tier and track.

**Goal:** Implement the approved unified-queue redesign (spec `.claude/specs/20260730-ui-redesign.md`) — sidebar gone, one queue + two verbs in a single pass per file, per-file overrides, history, scan consent, problems as rows, self-update — at handoff fidelity.

**Architecture:** Serial foundation first (models → engines → view model → design system: the whole shared layer lands before any parallel fork), then five file-disjoint parallel tracks (main screens, popovers/sheets, updater, R-net tests, DESIGN.md), then serial integration (shell rework, citation sweep, gates). `CompressViewModel` evolves into `QueueViewModel`; engines/stores are extended, never rewritten.

**Tech Stack:** Swift 5 / SwiftUI, macOS 14+, XCTest, xcodegen project, bundled Ghostscript (untouched).

## Global Constraints

- Spec is law: `.claude/specs/20260730-ui-redesign.md`. Design visuals/copy/motion: handoff at `$(git rev-parse --path-format=absolute --git-common-dir)/lcw/20260730-ui-redesign/handoff/` — README.md + `Toolbox Final.dc.html` + `renders/screen-*.png`. Where this plan and the spec disagree, the spec wins; report the conflict.
- Every source file: SPDX header `AGPL-3.0-or-later`, as every existing file.
- British English prose everywhere; code identifiers follow platform/API spelling.
- No new dependencies. No line-number citations in docs. Never reference the user's private test corpus.
- All numbers in UI `.monospacedDigit()`. Copy verbatim from the handoff except spec-recorded divergences (§6.3 "grew", §6.8 footer line, honest variant labels, §7 consent copy).
- Never delete/skip a failing gate test. Gates (`.claude/GATES.md`) must be green before the review-team gate.
- TDD per task: failing test → run (expect FAIL) → implement → run (expect PASS) → commit. Small conventional commits, one logical change each.
- Worktrees: foundation + integration tasks run in the LCW worktree (`.claude/worktrees/ui-redesign`, branch `feat/ui-redesign`). Parallel tracks run in their own worktrees under `.claude/worktrees/` branched off `feat/ui-redesign`, merged back on completion.
- Sibling tracks share nothing: a track touches ONLY its listed files. Test doubles and `Tests/ToolboxTests/Fixtures.swift`/`TestSupport.swift` are owned by track P-D once the fork happens; P-A/P-B/P-C add only NEW test files.
- Build/test command: `xcodebuild -project Toolbox.xcodeproj -scheme Toolbox test` filtered per task with `-only-testing:ToolboxTests/<Class>`; `TEST_RUNNER_` env prefix for env vars (repo gotcha). Regenerate the project with `xcodegen` after adding files.

---

## Phase F — serial foundation (LCW worktree, tasks in order)

### Task F1: Compound outcome model (`RowOutcome`) — Opus, foundation

**Files:**
- Modify: `Sources/Toolbox/Models/JobOutcome.swift` (replace enum with compound types)
- Modify: `Sources/Toolbox/Models/ToolJob.swift` (state carries `RowOutcome`)
- Modify: `Sources/Toolbox/Shared/ToolQueue.swift` (`JobResult` gains the compound)
- Modify (mechanical bridging only, no behaviour change): `Sources/Toolbox/Compress/CompressViewModel.swift`, `Sources/Toolbox/App/CompressSmoke.swift`, `Sources/Toolbox/Compress/CompressView.swift`, `Sources/Toolbox/OCR/OCRViewModel.swift`, `Sources/Toolbox/OCR/OCRView.swift` — switch sites updated to the new shape with equivalent behaviour
- Test: `Tests/ToolboxTests/RowOutcomeTests.swift` (new)

**Interfaces — Produces (later tasks rely on these exact shapes):**
```swift
// Models/JobOutcome.swift
struct RetainedVariant: Equatable {
    let kind: EngineVariant          // existing .mrc/.plain/.original (VersionStore.swift)
    let bytes: Int
    var searchable: Bool
}
enum CompressOutcome: Equatable {
    case compressed(before: Int, after: Int)     // after < before, compress artefact only
    case noGain(bytes: Int)
}
enum OCROutcome: Equatable {
    case added(pages: Int, skipped: Int)
    case alreadySearchable
    case tooFaint                                // ran, recognised nothing usable
    case failed(String)                          // user-facing message
}
struct RowOutcome: Equatable {
    var originalBytes: Int
    var finalBytes: Int                          // stat of the delivered file after ALL legs
    var compress: CompressOutcome?               // nil = verb off or leg skipped
    var ocr: OCROutcome?                         // nil = verb off or leg cancelled pre-OCR
    var runnerUp: RetainedVariant?               // non-nil = second variant retained (consent/capsule trigger)
    var grew: Bool { finalBytes > originalBytes }
}
enum JobState: Equatable { case queued; case analysing; case running(Double); case done(RowOutcome); case failed(String) }
```
`JobResult` becomes `{ outcome: RowOutcome, outputURL: URL?, alternateURL: URL?, mrcReport: MRCDocumentReport? }` (same field names as today, `outcome` re-typed).
The old `compressedHeavy` case is GONE — its information lives in `runnerUp`. `ocrAdded`/`alreadySearchable` map into `OCROutcome`.

**Steps:**
- [ ] 1. Write `RowOutcomeTests`: `testGrewIsDerivedFromFinalBytes`, `testRunnerUpDescriptorIndependentOfWinner` (a `RowOutcome` with `compress: .compressed` and `runnerUp: .init(kind: .mrc, …)` AND one with `runnerUp: .init(kind: .plain, …)` both construct — the gs-won retention case is representable), `testEquatable`. Run: expect FAIL (types missing).
- [ ] 2. Implement the types above; delete `JobOutcome`; mechanical bridging at every switch site (`ingestCompletedJobs`, `commit`, `recompressState`, `ToolQueue.process`, smoke, views): old `.compressed(b,a)` → `RowOutcome(originalBytes: b, finalBytes: a, compress: .compressed(before: b, after: a))`; old `.compressedHeavy(b,a,r)` → same plus `runnerUp: .init(kind: .mrc, bytes: r, searchable: false)`; old `.ocrAdded(p,s)` → `RowOutcome(originalBytes: n, finalBytes: n, ocr: .added(pages: p, skipped: s))`; old `.noGain` → `compress: .noGain`. Behaviour identical.
- [ ] 3. Full suite: `xcodebuild … test`. Expect PASS (bridging is behaviour-preserving; fix any site the compiler finds until green).
- [ ] 4. Commit: `refactor(models): replace JobOutcome enum with compound RowOutcome`.

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
              progress: @escaping (Double) -> Void) async throws -> JobResult   // now returns JobResult (RowOutcome inside)
```
Rules (spec §7 Per-file settings): `rebuildScan == true` never overrides classification eligibility (`.scanColour` only, complex-page rules stand — MRC R2); `preset == .maximumQuality` forces the MRC leg off regardless (MRC D3). A compress artefact ≥ input is withheld: winner ≥ input → `.noGain` (as today); a would-be runner-up ≥ input → no `alternateOutput` write, no descriptor.

**Steps:**
- [ ] 1. Extend `CompressEngineTests`: `testRebuildScanFalseSkipsMRCOnScanColour` (scanColour fixture + `rebuildScan: false` → no MRC leg: outcome has `runnerUp == nil` and gs output ships), `testRebuildScanTrueDoesNotForceIneligible` (bornDigital fixture + `rebuildScan: true` → plain Rung-1 path), `testRebuildScanIgnoredAtMaximumQuality`, `testRunnerUpAtOrAboveInputWithheld` (verifier override to force a bloated variant → `runnerUp == nil`). Run: FAIL (no param).
- [ ] 2. Implement: `let wantsMRC = (rebuildScan ?? (classification == .scanColour)) && classification == .scanColour && preset != .maximumQuality`; thread the withhold rule at the `alternateOutput` copy site; return `JobResult` with the descriptor populated from whichever variant was retained (kind `.mrc` when the hybrid is parked, `.plain` when gs is parked, `.original` when the untouched input is parked).
- [ ] 3. Run extended tests: PASS. Full engine suite: PASS.
- [ ] 4. Commit: `feat(compress): per-file rebuildScan override and >=input variant withhold`.

### Task F3: OCR split — recognise from original, append to any variant — Opus, foundation

**Files:**
- Modify: `Sources/Toolbox/OCR/OCREngine.swift`
- Test: `Tests/ToolboxTests/OCREngineTests.swift` (extend)

**Interfaces — Produces:**
```swift
struct RecognisedDocument {
    let pageText: [Int: [PositionedText]]     // Vision-normalised boxes (0…1, bottom-left) per page index
    let geometry: [Int: PageGeometry]         // ORIGINAL page geometry per index
    let pagesRecognised: Int
    let pagesSkipped: Int                     // pages that already carried text
}
extension OCREngine {
    func recognise(_ input: URL, options: OCROptions,
                   progress: @escaping (Double) -> Void) async throws -> RecognisedDocument
    // Appends to `target` (a compress variant OR a copy of the input), writing `output`.
    // Geometry rule: boxes are normalised, so they project onto the TARGET's own page geometry —
    // pass the target's mediaBox/rotation, not the original's, when the target is a composed
    // (MRC/bilevel) file whose pages are origin-(0,0), rotation-0, MediaBox = raster size.
    func append(_ recognised: RecognisedDocument, to target: URL, output: URL) throws
}
```
`ocr(_:to:options:progress:)` remains (re-expressed as recognise+append; behaviour identical for the OCR-only path). Existing verbatim-prefix validation (`hasVerbatimPrefix`, `validateOCROutput`) runs per append.

**Steps:**
- [ ] 1. Extend `OCREngineTests`: `testRecogniseThenAppendEqualsOcr` (same fixture through both paths → both outputs validate, same text pages), `testAppendToComposedGeometry` (fixture with a `/Rotate 90` scanned page → `mrcCompress`-shaped composed target (build via `MRCComposer` fixture path already used by `MRCInvariantTests`) → append → `PDFDocument` text selection returns the string at the expected upright position), `testAppendNeverTouchesTarget` (target bytes are a verbatim prefix of output; target file unmodified), `testOriginalNeverModified` (input mtime+bytes unchanged through recognise+append to a *different* target). Run: FAIL.
- [ ] 2. Implement the split. `recognise` = today's per-page render+Vision loop minus the write; `append` = today's `writer.appendTextLayer` call parameterised by target geometry (derive per-page geometry from the TARGET document at append time; assert page counts match, throw `OCRError.validationFailed` otherwise).
- [ ] 3. Run: PASS. Full OCR suite: PASS.
- [ ] 4. Commit: `feat(ocr): split recognise/append so text layers apply to any variant`.

### Task F4: QueueViewModel part 1 — rename, verbs, add-time inspection + reservation — Opus, foundation

**Files:**
- Rename: `Sources/Toolbox/Compress/CompressViewModel.swift` → `Sources/Toolbox/Queue/QueueViewModel.swift` (git mv; class renamed `QueueViewModel`)
- Create: `Sources/Toolbox/Queue/RowInspection.swift`
- Modify: `Sources/Toolbox/Shared/ToolQueue.swift` (admission during run), `Sources/Toolbox/App/RootView.swift` + `CompressView.swift` (mechanical rename only — full rework comes later)
- Test: rename `Tests/ToolboxTests/CompressViewModelTests.swift` → `QueueViewModelTests.swift` (mechanical), new tests in `Tests/ToolboxTests/QueueAdmissionTests.swift`

**Interfaces — Produces:**
```swift
struct RowOverride: Equatable { var preset: CompressPreset?; var rebuildScan: Bool?; var ocr: Bool? }
enum RowProblem: Equatable { case locked; case missing; case unreadable }
struct RowInspection: Equatable {
    var pageCount: Int?; var hasTextLayer: Bool?; var contentType: PDFContentType?; var problem: RowProblem?
    var metaLine: String   // "48 pages, mostly photographs" / "32 pages, no text layer yet" / "12 pages, text and vectors" — copy per handoff Ready screen
}
// QueueViewModel adds:
@Published var compressOn: Bool = true
@Published var ocrOn: Bool = false
@Published var ocrOptions = OCROptions()
@Published private(set) var overrides: [ToolJob.ID: RowOverride] = [:]
@Published private(set) var inspections: [ToolJob.ID: RowInspection] = [:]
func setOverride(_ o: RowOverride?, for id: ToolJob.ID)
func effectivePreset(for id: ToolJob.ID) -> CompressPreset
func effectiveVerbs(for id: ToolJob.ID) -> (compress: Bool, ocr: Bool)   // floor: never both false (spec §6.1)
func rebind(_ id: ToolJob.ID, to url: URL)   // "Find it…"
var canStart: Bool                            // ≥1 healthy row AND ≥1 batch verb on
```
Reservation: the run-start serial allocation pass MOVES to `add(_:)` (and `rebind`/override/folder/verb changes re-reserve while idle; settings lock per run — spec §6.5). `ToolQueue.add` accepts during a run; new jobs enter `.queued` and the active `execute` loop picks them up (extend the launch loop to re-poll queued jobs until the batch drains). Inspection runs on add off the main actor (`offloadBlocking`): `OpenGuard.inspect` + `pageHasText` sample + estimator analysis feed `RowInspection`; failures → `problem` set, row excluded from `canStart` counting.

**Steps:**
- [ ] 1. `git mv` both files; mechanical rename `CompressViewModel` → `QueueViewModel` repo-wide (`OCRViewModel` untouched — it dies in I1). Full suite: PASS. Commit: `refactor(queue): rename CompressViewModel to QueueViewModel`.
- [ ] 2. Write `QueueAdmissionTests`: `testAddDuringRunJoinsBatch` (stub engine with a gated first job; add a second mid-run; both complete), `testAddDuringRunReservesAgainstLockedSettings`, `testReservationReleasedOnRemove`, `testFolderChangeReReservesWhileIdle`, `testOverrideVerbFloorBlocksLastVerbOff` (`setOverride(RowOverride(ocr: false)…)` on an OCR-only batch's row → override rejected/clamped, effective verbs unchanged), `testProblemRowExcludedFromCanStart` (missing file → `canStart` false with only that row). Doubles: re-derive the shared stub's arity for width > 1 (concurrency lesson — the stub must support two concurrent in-flight jobs with independent continuations). Run: FAIL.
- [ ] 3. Implement part-1 surface above (verb flags, overrides + floor, inspection, add-time reservation + invalidation, `ToolQueue` admission, `rebind`). Run: PASS. Full suite: PASS.
- [ ] 4. Commit: `feat(queue): verbs, per-row overrides, add-time inspection and reservation`.

### Task F5: QueueViewModel part 2 — single-pass body, consent queue, progress/ETA — Opus, foundation

**Files:**
- Modify: `Sources/Toolbox/Queue/QueueViewModel.swift`
- Create: `Sources/Toolbox/Queue/BatchProgress.swift`
- Test: `Tests/ToolboxTests/QueuePassTests.swift` (new), `Tests/ToolboxTests/BatchProgressTests.swift` (new)

**Interfaces — Produces:**
```swift
struct BatchProgress: Equatable { let fraction: Double; let etaSeconds: Int?; let savedSoFarBytes: Int }
// QueueViewModel adds:
@Published private(set) var batchProgress: BatchProgress?
@Published private(set) var pendingConsents: [ToolJob.ID] = []      // FIFO, surfaced one at a time
@Published var rebuildWithoutAsking: Bool                            // UserDefaults-backed
func resolveConsent(_ id: ToolJob.ID, keepRebuilt: Bool)             // instant switch when needed
func legLabel(for id: ToolJob.ID) -> String?                         // "Compressing…"/"Rebuilding scan…"/"Reading page N of M"
```
Job body per file (spec §6.2/§6.4/§6.5/§6.8): compress leg (when effective-on, with per-row `preset`/`rebuildScan`) → cancellation check → OCR leg (when effective-on; width-2 semaphore; `recognise` from ORIGINAL, `append` to the delivered file via temp + `replaceItemAt`, and to the runner-up variant file when one was retained; append failure → variant `searchable = false`, never a job failure) → cancellation check → stat `finalBytes`, commit `RowOutcome`. Cancel between legs: keep-and-bank with meta "Compressed · not searchable — cancelled before reading". Consent: a completed job with `runnerUp != nil` and effective `rebuildScan` path appends to `pendingConsents` unless `rebuildWithoutAsking` (then auto-keep rebuilt when it exists+validates). ETA: smoothed completed-fraction rate, `nil` until batch fraction ≥ 0.1; "about" phrasing is the view's job.

**Steps:**
- [ ] 1. Write `QueuePassTests`: `testCompressThenOCRSingleRow` (both verbs → delivered file has text layer; `RowOutcome.compress` and `.ocr` both populated; `finalBytes` = actual stat), `testOCRAppliedToRunnerUpVariant` (forced MRC retention → BOTH files carry the layer; assert via `pageHasText` on each), `testOriginalVariantNeverAppended` (forced `.original` runner-up → file untouched, descriptor `searchable == false`), `testCancelBetweenLegsBanksCompressed`, `testOCROnlyRowNoSizeLie` (`compress == nil`, `finalBytes ≥ originalBytes` allowed, footer aggregates exclude it from savings), `testConsentQueuedFIFOAndResolved` (two forced retentions → `pendingConsents` in completion order; `resolveConsent(keepRebuilt: false)` swaps via `VersionStore`), `testRebuildWithoutAskingSkipsConsent`, `testOCRSemaphoreWidthTwo` (4 concurrent jobs, gated stub OCR → never >2 in OCR leg simultaneously). `BatchProgressTests`: fraction aggregation, ETA nil-before-10%, monotonic non-jitter. Run: FAIL.
- [ ] 2. Implement. Reuse `RunnerUpStore.switchVersions` for consent resolution; leg-boundary checks per the concurrency lessons (guard set before first await; check between engine return and commit).
- [ ] 3. Estimator calibration (spec §6.7): in `CompressEstimator.baseReduction`, raise `.scanColour` to MRC-path values (`.balanced: 0.75`, `.smallestSize: 0.80`, `.maximumQuality` unchanged at 0.12); extend `EstimatorTests` with `testScanColourPredictionTracksMRCPath` — prediction for the scanColour fixture within ±15% of the actual MRC pipeline output on that same fixture (fixture + pipeline call per `CompressEngineMRCTests` pattern). Run: PASS.
- [ ] 4. Run new tests: PASS. Full suite: PASS.
- [ ] 5. Commit: `feat(queue): single compress+OCR pass, consent queue, batch progress` + `feat(estimate): calibrate scanColour to the MRC path`.

### Task F6: HistoryStore — Sonnet, foundation

**Files:**
- Create: `Sources/Toolbox/Queue/HistoryStore.swift`
- Test: `Tests/ToolboxTests/HistoryStoreTests.swift`

**Interfaces — Produces:**
```swift
struct HistoryBatch: Codable, Equatable, Identifiable {
    let id: UUID; let date: Date
    let folderName: String; let folderURL: URL
    let fileCount: Int
    let presetTitle: String?                  // nil for OCR-only
    let compressOn: Bool; let ocrOn: Bool
    let savedBytes: Int                       // 0 for OCR-only
    let searchableCount: Int
    let partial: Bool; let problem: Bool; let cancelled: Bool
}
@MainActor final class HistoryStore: ObservableObject {
    static let retentionLimit = 200
    @Published private(set) var batches: [HistoryBatch] = []          // newest first
    @Published private(set) var lifetimeSavedBytes: Int = 0
    init(fileURL: URL? = nil)                                          // nil → Application Support/Toolbox/history.json
    func record(_ batch: HistoryBatch)                                 // prepends, trims to limit, adds savings, saves
    func clearList()                                                   // empties batches ONLY; lifetime survives (spec §6.9)
    var groupedByDay: [(label: String, batches: [HistoryBatch])]       // TODAY / YESTERDAY / date labels
}
```
Envelope on disk: `{"version":1,"batches":[…],"lifetimeSavedBytes":N}`. Unknown future version → start empty, never crash, never overwrite until next `record`. A cancelled batch records only if ≥1 file banked (spec §6.9).

**Steps:**
- [ ] 1. Write tests: round-trip, `testClearListPreservesLifetime`, retention trim at 200, day grouping labels, corrupt/foreign-version file → empty start, cancelled-with-banked records / cancelled-empty doesn't (enforced at call site — test the store's API contract: `record` always records; the VM decides). Run: FAIL.
- [ ] 2. Implement. Run: PASS.
- [ ] 3. Wire `QueueViewModel`: on batch end (incl. cancel-with-banked), build + `record` the `HistoryBatch`; test in `QueuePassTests`: `testBatchEndRecordsHistory`. Run: PASS.
- [ ] 4. Commit: `feat(history): recent-batches store with lifetime savings`.

### Task F7: Design system — tokens + queue components — Sonnet, foundation

**Files:**
- Modify: `Sources/Toolbox/DesignSystem/Theme.swift` (token overhaul)
- Modify: `Sources/Toolbox/DesignSystem/Components.swift` (restyle kept components: `PrimaryButton`, `LinkButton`, `StatPill`, `PDFThumbnail`, `LinearProgress`)
- Create: `Sources/Toolbox/DesignSystem/QueueComponents.swift`
- Test: `Tests/ToolboxTests/ThemeTests.swift` (new — token values), SwiftUI previews per component (build-checked)

**Interfaces — Produces (consumed by P-A/P-B):**
```swift
// Theme gains (values from handoff README §Design Tokens, light+dark via Color(light:dark:)):
Theme.Colors: bg, surface, text, text2, text3, accent, link, success, warn, danger, stroke, sep, hairline, fill, track
Theme.Radius: row = 10, control = 8, popover = 12, sheet = 14, gear = 13 (26pt circle), capsule = 980
Theme.Motion: standard = Animation.spring(response: 0.35, dampingFraction: 0.85); hover = .easeOut(duration: 0.15); press = 0.12; popover = 0.3; sheet = 0.38; banner = 0.45; checkPop = 0.45
Theme.Typography adds: windowHeadline (22/600, −0.3), sheetTitle (17/600), rowName (15/600, −0.2), bodyStrong (13/600), body13, meta (12), caption (11.5), sectionLabel (11/600, +0.4, uppercase)

// QueueComponents.swift:
struct VerbChip: View { let title: String; let suffix: String?; let isOn: Bool; let icon: Image
                        let toggle: () -> Void; let openOptions: (() -> Void)? }   // two actions, two a11y labels (spec §9)
struct StatusIndicator: View { enum Kind { case finished; case active(Double); case queued; case unchanged }; let kind: Kind }
struct CapsuleProgressBar: View { let fraction: Double }                            // 6pt, gradient fill, glow cap, sweep
struct OptionCard: View { let title: String; let value: String; let caption: String
                          let captionTone: Tone; let isSelected: Bool; let action: () -> Void
                          enum Tone { case success, muted, plain } }
struct QueueRow: View { /* full anatomy: thumbnail, name, meta(+accent), trailing sizes column (70pt),
                          hover gear, status slot, capsule; closures: onOpen, onGear, onCapsule, onRemove;
                          all hover affordances also keyboard-focusable (spec §9) */ }
struct BatchCard: View { let icon: StatusIndicator.Kind; let title: String; let subtitle: String; let action: () -> Void }
struct PopoverChrome<Content: View>: View  // radius 12, shadow 0 16 46 .24 + 0.5pt ring, popIn motion
struct SheetChrome<Content: View>: View    // radius 14, shadow 0 26 60 .34, sheetIn motion, dim 0.22
struct UpdateBannerChrome<Content: View>: View
```
Every interactive component: `.clearsClickFocus()` (standing invariant, memory 2026-07-25) + hover states per handoff + Reduce Motion variants (spec §9). Old `FileRow`/`DropZone`/`ToolHeader`/`SegmentedPreset`/`SuccessBanner`/`ToolIconTile`/`Card` stay untouched until I1 deletes them with their consumers.

**Steps:**
- [ ] 1. `ThemeTests`: assert exact light/dark token values (hex per handoff table), radii, motion durations. Run: FAIL. Implement tokens. PASS. Commit: `feat(design): handoff token set`.
- [ ] 2. Build `QueueComponents` with a preview per component covering every state (chip on/off/suffix, status kinds, card selected/plain, row hover/focus states). Build + previews compile; suite PASS. Commit: `feat(design): queue component library`.
- [ ] 3. Restyle kept components to token values (no API change). Suite PASS. Commit: `style(design): retoken kept components`.

**FORK POINT — after F7 merges, tracks P-A…P-E run in parallel worktrees.** Every track prompt carries: sibling tracks share the repo's branch history but each track has its own worktree; touch ONLY your listed files; never stash/revert/clean anything else.

---

## Phase P — parallel tracks

### Task P-A: Main-window screens — Sonnet, track A (worktree `.claude/worktrees/ui-redesign-a`)

**Files (create only):** `Sources/Toolbox/Queue/QueueView.swift` (state switch: empty/drag/ready/working/finished composition), `Queue/EmptyStateView.swift` (icon parallax + history strip), `Queue/DragOverlayView.swift` (tint, dashed ring, page fan, live count), `Queue/QueueHeaderView.swift` (title cluster, Add/Clear, ⋯ button, chips row, save-destination control), `Queue/QueueRowsView.swift`, `Queue/QueueFooterView.swift` (sums, Start/Cancel/finished buttons). Test: `Tests/ToolboxTests/QueueViewStateTests.swift` (new — state-selection logic only, no rendering assertions).

**Interfaces — Consumes:** `QueueViewModel` (F4/F5 exact surface), `HistoryStore` (F6), `QueueComponents` (F7), `FilePicker`. **Produces:** `QueueView(model:history:)` — the single view I1 mounts in `RootView`. Popovers/sheets are presented FROM here but their content views come from P-B: reference them by exact name/init — `QualityPopover(model:)`, `OCRPopover(model:)`, `PerFileSettingsPopover(model:jobID:)`, `ChangeQualitySheet(model:)`, `ScanConsentSheet(model:jobID:)`, `RecentBatchesSheet(history:)` — compile stubs for these do NOT belong to this track; guard the presentation wiring behind small local `@ViewBuilder` closures injected by `QueueView`'s init (`quality: () -> AnyView` etc.) so this track compiles alone and I1 plugs P-B's views in.
Visual truth per screen: handoff README §Screens + `renders/screen-01/02/03/05/06/10.png` + `Toolbox Final.dc.html` sections 01–03, 05, 06, 10. Copy verbatim; divergences per spec §6.3/§6.8/§7 (multi-active rows; truthful footer line "Toolbox works several files at once on your Mac's fastest cores."; "grew" meta; no Enter-password button — Skip/Remove/Find-it only).

- [ ] 1. `QueueViewStateTests`: state selection (empty vs ready vs working vs finished derives from model exactly — jobs empty→empty; any running→working; all terminal→finished; else ready), drop-during-every-state accepted, keyboard: Return on focused row invokes onOpen. FAIL → implement → PASS.
- [ ] 2. Build each view file against renders (entrance animations per handoff §Animations; Reduce Motion variants). Suite PASS after each file; one commit per view file, `feat(ui): <screen>`.

### Task P-B: Popovers + sheets — Sonnet, track B (worktree `…-b`)

**Files:** Create `Sources/Toolbox/Queue/QualityPopover.swift`, `OCRPopover.swift`, `PerFileSettingsPopover.swift`, `ChangeQualitySheet.swift`, `ScanConsentSheet.swift`, `RecentBatchesSheet.swift`; modify `Sources/Toolbox/Compress/VersionsPopover.swift` (redesign: radio list, ≤4 rows, honest searchability subtitles) and `Sources/Toolbox/App/AboutView.swift` (redesign per screen 11). Test: `Tests/ToolboxTests/PopoverLogicTests.swift` (new — selection/estimate maths only).

**Interfaces — Consumes:** `QueueViewModel` surface (F4/F5), `VersionStore.RowVersions.cards`, `HistoryStore.groupedByDay`, `QueueComponents`. **Produces:** the exact inits P-A references (list above — signatures frozen here: all take `@ObservedObject model: QueueViewModel` or `history: HistoryStore`, plus `jobID: ToolJob.ID` where listed).
Visual truth: renders 04/04b/04c/07/08/09/11 + HTML sections. Behaviour bindings per spec §7 (quality totals from estimator; queue dims 40%; consent card honesty incl. `.original` runner-up "Left as it was · original size"; change-quality duration lines only from measured rates; Recent batches footer "Clear list" → `history.clearList()`).

- [ ] 1. `PopoverLogicTests`: quality-popover totals recompute per preset from analyses; per-file estimate reflects overrides; change-quality card deltas derive from current rows; consent honest-copy switch for `.original` kind. FAIL → implement views → PASS.
- [ ] 2. One commit per view. VersionsPopover keeps its existing Quick-Look freeze pattern (lesson: collection never shrinks while panel alive).

### Task P-C: Self-updater — Opus, track C (worktree `…-c`)

**Files:** Create `Sources/Toolbox/App/SelfUpdater.swift`, `Sources/Toolbox/App/UpdateBanner.swift` (view; replaces RootView's private one at I1). Modify `Sources/Toolbox/App/UpdateChecker.swift` (parse asset URL). Test: `Tests/ToolboxTests/SelfUpdaterTests.swift` (new, fixture-served).

**Interfaces — Produces:**
```swift
// UpdateChecker.Release gains: let dmgURL: URL?   (first .dmg asset's browser_download_url;
//   parseRelease pins scheme https + host github.com or objects.githubusercontent.com; nil if absent)
@MainActor final class SelfUpdater: ObservableObject {
    enum Phase: Equatable { case idle; case downloading(Double); case verifying; case installing
                            case degradedToReleasePage(reason: String); case failed(message: String, asidePath: String?)
                            case relaunching }
    @Published private(set) var phase: Phase = .idle
    init(release: UpdateChecker.Release, session: URLSession = .shared, bundleURL: URL = Bundle.main.bundleURL)
    static func installDestination(for bundleURL: URL) -> URL?   // parent dir when it's a writable …/Applications; else nil
    func update() async
}
```
Flow exactly spec §6.10: sha256 of DMG vs `<dmgURL>.sha256` (fail → `.failed`); `hdiutil attach -nobrowse -plist` parse; payload + version check; strip quarantine on STAGED copy pre-swap iff `spctl -a -t exec` rejects (strip failure → abort pre-swap); aside-swap with every failure leg verified; on restore-failure the aside path lands in `.failed(asidePath:)`; detach best-effort; relaunch = write+spawn detached `/bin/sh` helper (`while kill -0 $PID; do sleep 0.2; done; open "<new bundle>"`), then `NSApp.terminate`.

- [ ] 1. `SelfUpdaterTests` against local fixture HTTP server + fixture DMGs (create tiny DMGs in test setup via `hdiutil create`): checksum mismatch → `.failed`, no swap; mount failure; wrong version in payload; `installDestination` nil for /tmp bundle → degrade; swap failure legs (make destination read-only mid-test) → working install remains, aside preserved + named on restore-failure; success path → old bundle at aside deleted, new in place. Never live GitHub. FAIL → implement → PASS.
- [ ] 2. Commits: `feat(update): release asset parsing`, `feat(update): self-updater state machine`, `feat(update): banner view`.

### Task P-D: R-net test re-derivation — Opus, track D (worktree `…-d`)

**Files:** Modify `Tests/ToolboxTests/QueueViewModelTests.swift` (renamed in F4), `Fixtures.swift`, `TestSupport.swift` (double arity for the two-leg pass), `Tests/ToolboxTests/ToolQueueTests.swift`, `VersionStoreTests.swift`, `RunnerUpStoreTests.swift` as consequences demand. No Sources/ edits — a needed VM change is a REPORT to the orchestrator, never an inline fix.

Protocol (spec §11): enumerate all 63 existing `QueueViewModelTests` funcs + the untagged early block; each gets a stated outcome: **adapt** (same invariant, new surface), **superseded-by** (name the replacing test), or **new sibling**. R1–R18 invariants all survive per spec §5 mapping (per-row presets; descriptor-keyed retention; R9's disable-during-run clause is REVERSED — its tests flip to assert admission; R19 reversed likewise). Deliverable includes the enumeration table as a file comment atop the test class.

- [ ] 1. Write the enumeration table first; commit it (`test(queue): R-net re-derivation map`).
- [ ] 2. Work group by group (the MARK groups listed in the class); suite green after each group; one commit per group.

### Task P-E: DESIGN.md rewrite — Sonnet, track E (worktree `…-e`)

**Files:** Modify `DESIGN.md` ONLY (citation sweep is I2's, in code files — not this track's).
Rewrite as the app's visual law from the handoff: token tables (light+dark), typography scale, spacing/radii/shadows, motion (curves+durations), component inventory, per-screen structure, copy register. **Preserve a Focus (Accessibility) section with the 2px accent outline requirement** — the stray-focus-ring invariant anchors to it (memory 2026-07-25). Keep numbered sections stable and listed in a header index so I2 can re-anchor code citations deterministically.

- [ ] 1. Rewrite; self-check against handoff README token-for-token; commit `docs(design): rewrite DESIGN.md to unified-queue redesign`.

---

## Phase I — serial integration (LCW worktree, after all tracks merge)

### Task I1: Shell rework + deletions — Opus

**Files:** Modify `Sources/Toolbox/App/RootView.swift` (single pane: mounts `QueueView(model:history:)` with P-B popover/sheet builders plugged into P-A's injection points; `⋯` menu = Recent batches… / Where files are saved… / About Toolbox; update banner wiring to `SelfUpdater`; window-level drop). Modify `ToolboxApp.swift` (app-menu About), `WindowConfigurator.swift` (min 900×640). Delete: `App/SidebarView.swift`, `App/Tool.swift`, `Compress/CompressView.swift`, `OCR/OCRView.swift`, `OCR/OCRViewModel.swift`, and from `Components.swift`: `FileRow`, `DropZone`, `ToolHeader`, `SegmentedPreset`, `SuccessBanner`, `ToolIconTile`, `Card` (grep-verify zero consumers first; `OCRViewModelTests.swift` deleted with its subject — its invariants live in `QueuePassTests`). Run `xcodegen`.

- [ ] 1. Wire, delete, build, full suite PASS, commit `feat(app): single-window unified-queue shell` + `chore(app): delete sidebar and legacy tool views`.

### Task I2: Docs, citations, DECISIONS, smoke — Sonnet

- [ ] 1. Citation sweep: `rg -n "DESIGN\.md"` repo-wide outside `.claude/` (42 expected pre-sweep) — re-anchor every reference to the new DESIGN.md sections; zero stale. Commit.
- [ ] 2. `UpdateChecker`/`SelfUpdater` doc comments + `.claude/OVERVIEW.md` boundary table: describe the user-initiated download path. `DECISIONS.md` entries: (a) self-update posture reversal (spec D1, trust model, revisit-when-signed), (b) MRC R7 asymmetry removal (spec §5), (c) combined-pass/per-file/drag-during-run deferral fulfilments. Cite `**Spec:** .claude/specs/20260730-ui-redesign.md`. Commit.
- [ ] 3. `CompressSmoke`: extend assertion to the compound shape (`result.outcome.compress` non-nil, `after < before`). Commit.

### Task I3: Gates + integration — Sonnet

- [ ] 1. Full `GATES.md` runbook: build, full suite, packaged-app gate, smoke. All green or stop-red.
- [ ] 2. Fixture-server updater functional pass (spec §11): install a build into `~/Applications`, one real update, assert old instance exits + new version relaunches.

**After I3:** LCW step 6 (review-team gate) → visual verification (computer-use screenshots vs `renders/`) → private-corpus functional pass → PR. These are workflow milestones, not plan tasks.

---

## Self-review notes

- Spec coverage walked §1–§14: every §6 architecture item has a task (6.1→F4/F5, 6.2→F5, 6.3→F1, 6.4→F3/F5, 6.5→F4, 6.6→F4, 6.7→F5-tests+P-B maths (estimator calibration constants land in F5 step 1's `QueuePassTests` via the estimator: see below), 6.8→F5, 6.9→F6, 6.10→P-C, 6.11→I1); every screen has a home (P-A/P-B); §8→F7/P-E/I2; §9 woven into F7/P-A/P-B; §11→P-D/I3.
- **Estimator calibration (spec §6.7)** is part of F5 scope: add `baseReduction[.scanColour]` MRC-path values (balanced ≈ 0.75, smallest ≈ 0.80, measured against repo synthetic fixtures in `EstimatorTests` — assert prediction for a scanColour fixture lands within ±15% of the MRC pipeline's actual output on that fixture) with `isFallback`/em-dash display rules in P-A/P-B.
- Type-consistency pass done: `RowOutcome`/`RetainedVariant`/`RowOverride`/`RowInspection`/`BatchProgress`/`RecognisedDocument`/`HistoryBatch`/`SelfUpdater.Phase` names match across all tasks; P-A consumes P-B's exact init list via injection, no cross-track compile dependency.
- Topological order verified: F1→F2→F3 (F2's JobResult return needs F1) →F4→F5 (needs F2/F3) →F6→F7; every P-track consumes only F-phase symbols; I1 consumes P-A+P-B+P-C.
