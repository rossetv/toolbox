# Recompress at a different quality — spec

**Date:** 2026-07-25 · **Branch:** `feat/recompress-quality` · **Status:** awaiting human approval

## Origin — the problem before the solution

After a batch compresses, the results screen still shows the quality selector
(`SegmentedPreset`, enabled whenever `!model.isRunning`), but selecting a different quality
does nothing for finished rows — `reestimatePendingJobs()` republishes estimates for *queued*
rows only. The user's words: *"selecting a different quality does nothing. It should support me
selecting a different quality, either lower or higher, and then the button changes to
'Recompress' … that allows me to change the quality if I think the quality is too shit or the
file is still too big."* Both triggering complaints are post-hoc discoveries by nature: a byte
estimate cannot show MRC softening, so no pre-run preview prevents them. The only honest answer
is a re-run — this spec makes the already-visible selector the recovery path.

## Decisions (locked with the human)

| # | Decision | Why (the human's terms) |
|---|----------|-------------------------|
| D1 | **Preview on select.** Changing the preset with finished rows showing arms a recompress visibly; nothing runs until the button is pressed. Fully reversible by re-selecting. | Seeing what you'd get before spending it; the dead control becomes the recovery path. |
| D2 | **Recompress always from the ORIGINAL input**, never the compressed output. | No compounding artefacts; "originals are never modified" stays true. |
| D3 | **One previous version per row, switchable** — not a per-preset matrix. | The problem is *undo one step*, not compare-shopping; a matrix of files that evaporate at quit is ceremony. Chosen explicitly over "replace it" and over the matrix. |
| D4 | **Ship what was asked.** A higher-quality result bigger than the current version still ships, sizes shown honestly. | The user explicitly chose the quality — deliver it; don't second-guess. |
| D5 | **Batch-level control only.** No per-row quality pickers, no per-row opt-out in v1. | The preset is already a batch control; per-row is deferred until it actually annoys. Armed-row layout must leave room for a leading checkbox later (expected first follow-up). |
| D6 | **Cache is session-only and never grows.** Parked versions live in the runner-up cache: swept at launch, wiped at quit, and discarded by "Clear finished" for the cleared rows. | The human: "this cache should be wiped when the application is closed or someone hits Clear, so we're not growing a cache forever." |

### Rejected alternatives (one line each)

- *Replace the old version outright* — human chose switchable instead.
- *Per-preset version matrix* — (preset × variant) slots, popover redesign, per-slot
  regeneration; over-built for undo-one-step.
- *Per-row quality menus / opt-out* — fights the batch design; deferred, layout kept ready.
- *Target-size input ("get under 5 MB")* — different feature; useless for the quality case.
- *"Try all presets" one-shot* — 3× compute for a recovery flow.
- *Re-queue rows through `ToolQueue`* — verified unworkable: `execute` collects `.queued` only;
  cancel maps to `.queued` (destroying the done state), failure to `.failed`; `setState` drops
  `.running` ticks on `.done` jobs. The direct-engine path (below) is the only route that
  preserves a delivered result through a re-run.
- *Keep versions across quits (named files, e.g. `-compressed-balanced.pdf`)* — contradicts the
  v1 spec's §5.4 output-naming rule (one `<name>-compressed.pdf`, never overwrite) and D6's
  no-persistent-cache; rejected.

## UI reference

Approved mockup (built from Theme.swift tokens and real component geometry, light + dark):
<https://claude.ai/code/artifact/fd39f6b6-3716-4288-88b8-ef8f482802e7>. Five screens: finished
baseline, armed state, running, versions popover, edge states. The mockup source is captured
in-repo at `.claude/specs/20260725-recompress-quality-evidence/recompress-ux-mockup.html`
(open in any browser) so future sessions don't depend on the artifact URL. It is the visual
contract for R1–R8 below; where prose and mockup disagree, this spec wins and the mockup gets
fixed.

## Requirements

### Arming (the preview state)

- **R1 — Who arms.** With no run in flight, selecting preset P arms every job whose *row
  preset* ≠ P and which can recompress: `.done(.compressed)`, `.done(.compressedHeavy)`, and
  `.done(.noGain)` rows arm; `.failed` rows never arm (their recourse is re-adding the file);
  `.queued`/`.analysing` rows are untouched (they will simply run at P). **A row's preset** is:
  the shipped version's recorded preset where one exists (R14), else the recorded preset of its
  most recent attempt (rows that have shipped nothing — noGain). A first-run
  noGain at P0 records (job, P0) as futile exactly as a recompress noGain does (R6), so
  re-selecting P0 shows the futile caption, never a re-arm. A job whose row preset = P is not
  armed. Arming is pure view-model state — `job.state` does not change.
- **R2 — Armed row appearance** (mockup screen 2). The row keeps its full done cluster
  (struck original, current size, saved pill, checkmark) and gains: a leading accent pill
  `→ ≈<predicted>` (or `→ may not shrink`, R16), and an accent caption appended to the meta
  line: "will recompress at <preset title>" ("will try <preset title>" for noGain rows). The
  armed style is additive — nothing reads as lost.
- **R3 — Reversibility.** Re-selecting a preset that matches a row's shipped version disarms it
  instantly; when no row is armed the UI is exactly the step-1 finished state. No state survives
  disarming except the futile-attempt record (R6).
- **R4 — Banner and footer in the armed state.** While ≥1 row is armed: the success banner is
  replaced by an accent armed banner — "Will recompress N PDF(s) at <preset title>" — and the
  footer's primary button reads "Recompress N PDFs". The banner's detail line depends on the
  summed prediction — summed over armed rows with a confident prediction only; "may not shrink"
  rows contribute nothing: positive extra saving → "≈ saves another <bytes>"; zero-or-negative (the
  quality-upgrade direction) → "files may grow for the extra quality"; every armed row "may not
  shrink" → no detail line. In the mixed state (R5) the banner headline is "Will compress K and
  recompress M PDFs" with the same detail rules over the armed rows only. Both fixed regions
  carry the story because armed rows may be scrolled off. "Reveal in Finder" / "Compress More"
  (the `allFinished` affordances) are hidden while armed or running.
- **R5 — Mixed queued + armed.** Newly added files and armed rows form ONE run behind ONE
  button: title "Compress N PDFs" when only queued rows exist, "Recompress N PDFs" when only
  armed rows exist, "Compress K · Recompress M" when both. One press runs both sets in the same
  bounded batch (R9); one Cancel governs all of it.
- **R6 — Futile-attempt suppression.** A recompress attempt at preset P that returns noGain
  records (job, P) as futile; re-selecting P later shows the row disarmed with the caption "No
  saving at <preset title>" instead of re-arming a known-futile run. The record dies with the
  row (Clear finished / remove) or the session.
- **R7 — Instant switch.** If the selected preset P matches the *parked previous version's*
  preset (R14), the row does not arm a re-run: caption "your <preset title> version is kept",
  trailing link "Switch instantly" performs the version switch (R14) directly. No recompute of
  a file already in the cache.

### Execution

- **R8 — Direct-engine path.** Recompress never re-queues through `ToolQueue`. It generalises
  the `rerunForSwitch` pattern: `engine.compress` called directly per job, progress overlaid on
  the row while `job.state` stays `.done` until a successful result is committed. The row's
  displayed state flips only at commit time.
- **R9 — Batch semantics.** Concurrency bounded to the same width as a normal batch
  (`SystemInfo.performanceCoreCount`); a running bar "Recompressing X of N… Cancel"; the preset
  selector, "+ Add", "Clear finished", output-folder row, and drop target disabled/refused for
  the duration (whatever flag drives this must cover the direct path — today's `isRunning`
  reflects only `ToolQueue`). Cancel stops undispatched jobs and cancels in-flight ones; every
  uncommitted row keeps its previous result and display untouched.
- **R10 — Missing-original guard.** Before running (and before arming shows a confident
  estimate), each armed job's input must still exist; a missing input yields the per-row error
  "The original file is no longer where it was" (mockup screen 5), leaving the row's shipped
  result and versions intact. The rest of the batch is unaffected.
- **R11 — Output path pinned.** A recompress writes to the row's *existing* result path, even
  if the "Save to" folder changed since the first run. noGain rows (no result path yet) allocate
  from the current folder via the normal reservation. The existing result path is seeded into
  the reservation set explicitly — correctness must not depend on the file happening to exist at
  allocation time (the promote window makes it transiently absent).
- **R12 — Commit protocol.** New result written to a dot-temp; on success the old shipped file
  is parked into the version store's previous slot and the temp promoted to the result path
  atomically (`replaceItemAt`-class semantics; the old version survives any failure). On
  engine failure: temp cleaned up, row shows the per-row error "Recompress failed — kept your
  <preset title> version" with the previous result still displayed and openable — an explicit
  button press NEVER fails silently (the switch path's quiet revert is not replicated). On
  noGain: nothing shipped, previous version and its display retained, row caption per R6, and
  `resultURL`/version references NOT cleared (the current `.noGain` outcome carries no URLs, so
  the commit path must not route through the state-overwrite that would nil them).
- **R13 — Ship what was asked (D4), bounded by the original.** A result larger than the current
  version but smaller than the original ships, with honest sizes (no success pill when
  `new ≥ original`, matching the existing heavy-row rule). A result ≥ the original is noGain
  (R12).

### Versions

- **R14 — Version store.** A view-model-owned store is the single source of truth for a row's
  versions: for each job, the shipped version plus up to two parked versions — the current
  run's engine runner-up (existing heavy/gs race) and ONE previous version (D3) — each recorded
  as (URL, bytes, preset, engine variant). It replaces the scattered bookkeeping (`switched`
  set, `jobPresets`, frozen byte payloads read out of `JobOutcome`, `batchAlternates`) as the
  display authority; a second recompress replaces the previous slot and discards the file it
  held (no cache leak — every superseded cache file is discarded at replacement time, not
  quit). The preset lives on the version record, not the job: the existing invariant that a
  later batch must not rewrite a finished row's preset
  (`testLaterBatchDoesNotRewriteAFinishedRowsPreset`) must keep holding.
- **R15 — Versions capsule + popover** (mockup screen 4). The capsule renders on ANY row with
  ≥2 versions, regardless of outcome shape — including a Maximum-quality re-run that came back
  plain gs (today's capsule draws only on `.doneHeavy`). Title: "Heavy compression" when the
  only parked version is the current run's runner-up (today's vocabulary preserved),
  "Versions" once a previous version exists — and while only the runner-up is parked the
  existing dynamic title family survives unchanged ("Heavy compression" / "Normal compression"
  / "Original" per `HeavyVersions.capsuleTitle`), so a switched row keeps its honest label. The
  popover generalises the existing card UI:
  2 cards at today's 340 pt, 3 cards at 470 pt; card labels carry preset + variant
  ("Smallest · Heavy", "Smallest · Normal", "Balanced (previous)"); each card previews in
  Quick Look and non-current cards carry "Use this". Switching any card in ships that version
  via the store (park/promote per R12's safety); all aggregates re-derive (R17). The Quick Look
  frozen-items collection may only grow or be overwritten, never shrink while the panel is
  alive (standing lesson).
- **R16 — Estimate honesty.** The armed pill's prediction: scale the estimator's per-preset
  figure by the row's observed ratio (actual result ÷ estimate at the row preset) ONLY when the
  engine path is expected to repeat — i.e. the shipped engine variant and the target preset's
  MRC eligibility *for this row's classification* agree (`wantsMRC`: `.scanColour` ∧ preset ≠
  `maximumQuality`; a born-digital row is gs on every preset, so its path always repeats and it
  always scales). Whenever the path changes in EITHER direction — an MRC-shipped row crossing to
  `maximumQuality` (never MRC-eligible), or a gs-shipped row (including a `.scanColour` row
  shipped at Maximum quality, or one where MRC lost the document gate) moving to an
  MRC-eligible preset — use the RAW gs estimate: a ratio learned on one path does not transfer
  to the other. The store's per-version engine variant (R14) plus the row's classification make
  the direction decidable. Any prediction ≥ the original renders as "may not shrink" (never a
  confident number), and the "≈" marker stays throughout.

### Consistency and boundaries

- **R17 — Aggregator sweep.** Every sibling display that derives from `job.state`/`JobOutcome`
  re-derives from the version store, enumerated so none is left summing the old model —
  `CompressView`: `savedBytes`, `savedDetail`, `savedSummary`, `status(for:)`,
  `originalBytes(for:)`, `revealOutputs`, `open`, `overallProgress`, `pendingCount`,
  `finishedCount`, `outputNamePreview`, `canRemove`; `CompressViewModel`: `displayedSizes`,
  `heavyVersions`, `allFinished`, `isDoneHeavy`, `discardRunnerUp`, `publishJobs`. (Standing
  lesson: after fixing a state-display bug, grep every sibling aggregator over the same enum.)
- **R18 — Cache lifecycle (D6).** Parked versions live under the existing runner-up cache
  root: swept at launch (`sweepStale`), wiped at quit (`removeAllOnDisk`), and "Clear
  finished" / row removal discards the cleared rows' parked files immediately. Switching is
  offered only while the app runs; no persistent state is introduced (spec R15 of the compress
  spec — the no-persisted-state exception — is unchanged in scope).
- **R19 — Shared layer.** `ToolQueue` is shared with OCR. The recompress path lives entirely in
  the Compress view model; any `ToolQueue` change must be behaviour-preserving for OCR
  (`resultURL ?? url` open fallback, `.alreadySearchable` handling). OCR gains no recompress
  behaviour.
- **R20 — Tests.** Regression tests accompany: arming/disarming rules incl. noGain-arms-down
  and futile suppression (R1/R6); instant-switch routing (R7); commit protocol — success,
  failure-keeps-previous, cancel-keeps-previous, noGain-keeps-references (R12); output-path
  pinning + reservation seeding (R11); version-store replacement discards the superseded cache
  file (R14); capsule-on-plain-row (R15); estimate boundary behaviour (R16); mixed-run button
  counts (R5). Test doubles must reproduce the production write contract — never-overwrite
  delivery — not just output bytes (standing lesson).

## Verification evidence

Claims verified against code during two review passes (Opus adversarial 2026-07-25, Fable
design review 2026-07-25), each reading the named files first-hand:

- `SegmentedPreset` enabled-but-inert after finish; `reestimatePendingJobs` touches queued only.
- `ToolQueue.execute` collects `.queued` only; `process` maps cancel → `.queued`, error →
  `.failed`, assigns `resultURL`/`alternateURL` unconditionally; `setState` drops running ticks
  on done jobs — the re-queue route destroys delivered state (rejected alternative above).
- `rerunForSwitch` demonstrates the preserve-state direct path: engine call, `rerunProgress`
  overlay, `freshShipped` temp + `replaceItemAt` promote, prior state kept on failure.
- `jobPresets` is one-preset-per-job and load-bearing for the R10 re-run;
  `testLaterBatchDoesNotRewriteAFinishedRowsPreset` pins it.
- `wantsMRC = classification == .scanColour && preset != .maximumQuality` — Maximum quality is
  always plain gs; the calibrated ratio cannot cross that boundary.
- `CompressEstimator` models gs only (flat per-content-type reductions) — uncalibrated it
  predicts a heavy row's recompression *grows* the file ~4×.
- `RunnerUpStore` is session-only (swept at launch, `removeAllOnDisk` at quit) and its
  `switchVersions` implements the park/promote/restore contract R12 reuses.
- `FileRow` draws the capsule only in `.doneHeavy`; `HeavyCompressionPopover` is 340 pt, two
  cards, one binary switch button.
- `outputFolderRow` is live post-run — the drift R11 pins against is reachable today.

## Risks

- **Estimate calibration (R16) scales only when the engine path is expected to repeat**, with
  path-change in either direction routed to the raw estimate. Residual risk: a document whose
  MRC eligibility flips between two MRC-eligible presets via the D7 document gate can still
  deviate from the scaled figure — accepted, the pill is explicitly approximate ("≈").
- **One combined run driving two mechanisms (R5)** — queued rows via `ToolQueue`, armed rows
  via the direct path — risks 2× concurrency if run simultaneously. Resolution is the plan's
  to choose (serialise sets, or share one bound); the spec constrains only the observable:
  one button, one progress bar, one cancel, total concurrency ≤ the normal batch width.

## Prior-spec references

- `.claude/specs/20260723-mrc-rung3.md` R6/R7/R9–R11/R15 (runner-up store, switch flow,
  Quick Look freeze, no-persisted-state exception) — extended here, not contradicted.
- `.claude/specs/20260722-pdf-toolbox-v1.md` §5.4 (output naming, never-overwrite delivery)
  and the never-emit-larger rule R13 mirrors — unchanged in scope.
- `.claude/memory/review-lessons.md` — standing checks applied: shared layer before parallel
  fork (plan stage), aggregator sweep (R17), stub write semantics (R20), Quick Look
  never-shrink (R15), up-front serial name reservation (R11).
## Round 1 — 2026-07-25 — NO-SHIP (spec-reviewer, Fable 5)
2 major (R16 one-directional carve-out, R1 noGain preset undefined), 7 minor (R15 title family, R4/R5 mixed+upgrade banner, R7 cross-ref, dangling D4 citation, unnamed prior specs, unverifiable mockup URL, false .failed parenthetical). All fixed this round. Lesson-candidates: resolve every D/R pointer; audit carve-outs both directions; define rules for outcome shapes that ship nothing; capture visual contracts in-repo.
## Round 2 — 2026-07-25 — SHIP pending certify (spec-reviewer, Fable 5, incremental)
Both majors verified fixed; 7 minors verified fixed; 3 new minors (R1 gloss vs operative clause, R4 sum membership, R16 per-row eligibility phrasing) fixed this round. Lesson-candidates: check a gloss against operative clauses for every state history; state aggregate membership when rows can be non-numeric; phrase joint eligibility per-row.
