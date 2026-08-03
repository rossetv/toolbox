<!-- Claude-maintained; humans never edit. Registered in .claude/INDEX.md — an
unregistered KB file is a defect. Every path, command, and constant below must
be verified against the code before writing; on contradiction, fix here at
once. Unknown fact → omit the section, never guess.
NEVER cite a line number (no `file.sh:234`, no bare `(:234)`, no ranges): any edit
above it rots the citation, and re-numbering then eats the whole maintenance budget.
Cite the file plus a stable, greppable anchor — a function, variable, constant or
check name: `scripts/kb-gate-lib.sh` (`review_key()`). Verify the anchor with grep. -->
↑ [INDEX](../../INDEX.md)

# Module: Queue

## Purpose

The whole window's content and the single view model behind it. There is one queue,
one job list and one pass: **Compress and OCR are verbs of that pass, not two tools**
(spec §6.2), so this module owns everything the old per-tool views and view models
did — dropping/adding files, add-time inspection, per-row overrides, the run and its
progress/ETA, the finished screens, the scan-consent and version-switch flows, and
the recent-batches history. [Compress](compress.md) and [OCR](ocr.md) document their
own engine-facing surface of `QueueViewModel`; this doc owns the queue-wide mechanics.

## Key files

| File | Role |
|------|------|
| `Sources/Toolbox/Queue/QueueViewModel.swift` | `@MainActor` state for the whole queue: the verb set, preset/output folder, per-row `overrides`/`inspections`, the delivery reservations, the run (`compress()`, `cancel()`), leg progress + ETA, the consent queue, the version switch, the recompress phase |
| `Sources/Toolbox/Queue/QueueView.swift` | The window's single content view: `QueueScreenState` (`empty`/`ready`/`working`/`finished`/`problems`) as one state machine derived through `QueueRowPartition.classify`, and constructs every popover/sheet it presents directly (Quality/OCR/per-file/versions/change-quality/scan-consent/recent-batches/About) — `RootView` only supplies `model`, `history` and the externally-owned `showAbout` binding (see [App](app.md)) |
| `Sources/Toolbox/Queue/QueueHeaderView.swift` | Top strip in every non-empty state — title, verb chips, save-destination row, working progress bar, finished/problems headlines, and the `⋯` menu |
| `Sources/Toolbox/Queue/QueueRowsView.swift` | The scrollable list: one row shape (`QueueRow`) whose trailing content and copy are composed per row; `QueueByteFormat` is the byte formatting the header/rows/footer share |
| `Sources/Toolbox/Queue/QueueFooterView.swift` | Bottom bar in every non-empty state — estimate + Start, saved-so-far + Cancel, save location + Show in Finder/Change quality/Add More |
| `Sources/Toolbox/Queue/EmptyStateView.swift` | First-run/idle screen: Choose Files…, the "nothing leaves this Mac" reassurance, and the two most recent batches |
| `Sources/Toolbox/Queue/DragOverlayView.swift` | The full-bleed drag-over overlay, drawn atop whatever screen is underneath |
| `Sources/Toolbox/Queue/RowInspection.swift` | `RowOverride` (sparse per-row settings) + `RowInspection` (what add-time inspection learned: page count, text layer, `RowProblem`) |
| `Sources/Toolbox/Queue/QueueRowPartition.swift` | `QueueRowPartition.classify` — the ONE row-partition predicate (delivered / failedActionable / failedSkipped / problemUnresolved / problemSkipped / cleanPending / cleanSkipped / transient); `QueueView.screenState`, `QueueHeaderView`'s problems headline/subtitle and `QueueViewModel.healthyQueuedCount` all derive from it |
| `Sources/Toolbox/Queue/BatchProgress.swift` | `BatchProgress` — the run's `fraction`, `etaSeconds` and `savedSoFarBytes`, the one figure the rows cannot cheaply re-derive per render |
| `Sources/Toolbox/Queue/HistoryStore.swift` | `HistoryBatch` + `HistoryStore` — the schema-versioned recent-batches JSON and the lifetime savings counter |
| `Sources/Toolbox/Queue/QualityPopover.swift`, `OCRPopover.swift` | The batch-level Quality (three priced presets) and OCR (language + accuracy) popovers |
| `Sources/Toolbox/Queue/PerFileSettingsPopover.swift` | One row's Quality/Rebuild/OCR override, committed immediately through `QueueViewModel.setOverride(_:for:)` — no OK/Cancel, only "Match the batch" |
| `Sources/Toolbox/Queue/ChangeQualitySheet.swift` | Change quality on the Finished screen: preset cards priced from the current rows, previewing by moving `model.preset` itself |
| `Sources/Toolbox/Queue/ScanConsentSheet.swift` | The scan-rebuild choice (Keep rebuilt / Keep photographs), one row at a time |
| `Sources/Toolbox/Queue/VersionsPopoverContent.swift` | A finished row's versions capsule: in-use/alternative/previous/original as radio rows, each switchable in one tap |
| `Sources/Toolbox/Queue/RecentBatchesSheet.swift` | The history sheet: batches grouped by day, the lifetime total, and "Clear list" |

## Invariants

- **`ToolQueue.jobs` is the source of truth for lifecycle state; `QueueViewModel`
  never mutates it.** `publishJobs()` rebuilds the published `jobs` as value copies of
  `rawJobs` with the local estimate and the `.analysing` overlay merged in, and never
  overrides a state the queue has already moved past `.queued`. `.analysing` is a
  view-model-only state — `ToolQueue` never produces it (`JobState`, see
  [Models](models.md)).
- **Compress and OCR are verbs with a floor on one side only.** `compressOn`/`ocrOn`
  are batch-level; `RowOverride` deliberately has no `compress` field (the per-file
  popover offers exactly Quality, Rebuild the scan, Read the text), so
  `effectiveVerbs(for:)` only has to stop a row turning off its last verb. `canStart`
  refuses when both batch verbs are off. `effectivePreset(for:)` resolves the row's
  preset the same way.
- **A run locks its settings at the start** (`lockedRun`, read through
  `activeSettings`): every job of that run — including rows dropped in while it is
  live — takes its destination, verbs and preset from the lock, so settings the user
  moves mid-run cannot retarget work already in flight. `activeSettings` is one
  accessor rather than two paths because arming already stands down for the run's
  duration (`recompressState(for:)`'s `!isRunning` guard).
- **Delivery names are reserved when a file is ADDED, not at run start** (spec §6.5):
  `reserveDelivery(suffix:for:)` allocates against `reservedKeys(excluding:)` — the
  ledger already handed to every other row — which is what makes dropping files
  mid-run safe. Changing the output folder or the verb set calls
  `invalidateReservations()`. See `FileNaming.output(for:suffix:folder:reserving:)`
  in [Shared](shared.md) for why a bare on-disk existence check races.
- **One row, two legs, one continuous progress span.** `compressLegWeight` (0.5)
  splits a row's 0…1 into a compress span and an OCR span (`LegSpan`, `legSpans`), so
  a row running both verbs never restarts its bar at the hand-off;
  `legLabel(for:)`/`rowETASeconds(for:)` map the composed fraction back onto the leg
  actually running. A row with only one verb gets the whole span.
- **ETAs are gated on evidence and never count upwards.** `legETASeconds` (per leg,
  un-smoothed) and `smoothedETA` (per batch, exponentially smoothed with a fixed 0.3
  weight) both return nil below 10% progress, and the batch figure is clamped to the
  previous value so a late slow tick cannot make the countdown jump back up.
  `BatchProgress.fraction` is **not** monotonic: a file dropped in mid-batch grows the
  denominator.
- **Money figures come from `VersionStore`, never from `job.state`'s `RowOutcome`**
  (`savedSoFarBytes`): the outcome stays the row's original pass result for ever once a
  recompress has landed, so only the version store knows a row's current size. A
  rescue, a no-gain row and an OCR-only delivery record no `shipped` version and
  contribute nothing.
- **The scan-consent queue is FIFO, mid-run, and one sheet at a time**
  (`pendingConsents`): each entry arrives as its own file's delivery completes, so a
  batch of scans asks about the first while the rest are still compressing. Both
  variants are already on disk, so `resolveConsent(_:keepRebuilt:)` is an instant
  version switch, never a re-run. The row leaves `pendingConsents` **before** the
  switch is attempted — a choice the user has just made must not re-surface as a sheet
  if the swap fails; the failure is reported beside the row and the versions capsule
  still offers the same switch.
- **`switchesInFlight` is the single re-entrancy guard for every version switch**
  (`beginSwitch`, released by `keepVariant`'s `defer`): the consent sheet's buttons,
  the popover's "Use this", `compress()` and `clearFinished()` all consult it, so two
  taps land one switch. `useVersion(_:for:)` is instant while the parked file exists;
  if the runner-up has vanished, `rerunForSwitch` honestly re-runs that one job through
  the engine and applies the requested switch on completion (R10).
- **"Find it…" is a full row reset that keeps the row's `id`** (`rebind(_:to:)`,
  backed by `ToolQueue.rebind(_:to:)`): the row now describes a different document, so
  inspection, versions, futility, analysis and any recorded failure all go with the old
  file — but the surviving `id` is what keeps the row's overrides, reservations and
  place in the queue.
- **Degraded is not failed** (`RowOutcome.isDegraded`, see [Models](models.md)): a
  rescued row whose compress leg failed, a read that found nothing usable, a read
  cancelled between the legs and a read that failed after delivery all warn while
  keeping their delivered file — because the Problems footer's promise that failed
  files were not touched at all must stay true.
- **`HistoryStore` never clobbers a file it does not understand**: the on-disk envelope
  is schema-versioned (`currentVersion` 1) and an absent, corrupt or foreign version
  starts empty in memory and is left untouched on disk until the next `record()`.
  `record()` trims to `retentionLimit` (200) and folds the saving into
  `lifetimeSavedBytes`, which is a running total — it survives `clearList()` and does
  not shrink when a batch is trimmed past the cap.
- **A batch is recorded from this run's freshly-queued rows only**
  (`recordBatchHistory` over `runQueuedIDs`, never `batchRowIDs`): an armed
  (recompress) row's saving is its lifetime delta, already counted by the batch that
  first delivered it, so a pure recompress records no batch at all.
- **`QueueScreenState` is derived on every read, never stored** — the screen cannot
  disagree with the model it is computed from.
- **Sheets present in-window, not as system sheets** — one `QueueSheet` enum (unchanged) now
  drives a `.overlay` on `QueueView` (`sheetContent(_:)`) instead of `.sheet(item:)`: `SheetChrome`/
  `AboutView` already draw their own dim + card, so a system sheet wrapped that in a second
  window-shaped container. `.disabled(activeSheet != nil)` +
  `.accessibilityHidden(activeSheet != nil)` on the screen underneath restore the modality a system
  sheet gave for free (a focusable `QueueRow` answers Return by opening the file underneath the
  dim), and `escapeToDismiss` (see [DesignSystem](design-system.md)) restores Escape. Every drop
  entry point (`QueueDropDelegate.validateDrop`/`dropEntered`/`dropUpdated`/`performDrop`) now reads
  a live `sheetPresented` closure, not just `performDrop`: `QueueView.shouldAcceptDrop(modalWindowPresented:sheetPresented:)`
  refuses while either a modal panel (`FilePicker`) or an in-window sheet is up — `NSApp.modalWindow`
  is nil for the latter by construction, so it must be passed explicitly.
- **A row's override is judged by its EFFECTIVE settings, never by "does an `overrides[id]` entry
  exist"** (`QueueViewModel.differsFromBatch(_:)`): the "Its own settings" mark (`QueueRowsView`),
  the per-file popover's "Reset override" visibility, and the ready footer's divergence line
  (`QueueFooterView.readySubline`) all read it. `setOverride(_:for:)` also collapses any field that
  now says exactly what the batch says (`collapsingBatchMatches`, compared against `activeSettings`
  — never the live published `preset`/`ocrOn`, which are wrong mid-run) — including an `ocr: false`
  that `effectiveVerbs` floors back on when Compress is off — so a row that has drifted back to the
  batch keeps no entry and re-follows the batch if it moves again.
- **Change quality clears a row's PRESET override on selection, never its OCR/rebuild fields**
  (`ChangeQualitySheet.applySelectionToIncludedRows`, called on `.onAppear` and from every card):
  `recompressState`/`recompressPrediction` key off `effectivePreset(for:)`, so an overridden row's
  own preset silently outranked the sheet's choice until this cleared it. The full restore set on
  every non-confirmed exit is now three snapshots — `initialPreset`, `initialExclusions` **and**
  `initialOverrides` (`ChangeQualitySheet.restoreOverrides`, keyed over the union of the snapshot's
  and the live `overrides`' keys so a row added while the sheet was open restores to `nil`).

## Gotchas

- `QueueViewModel.history` is deliberately not `private`: `QueueView` and
  `RecentBatchesSheet` hold it as their own `@ObservedObject`, because a nested
  `ObservableObject`'s changes do not propagate through the owning view model's
  `objectWillChange`. It is constructed once, in `QueueViewModel`, never a second time.
- `ChangeQualitySheet` previews by genuinely (and reversibly) moving `model.preset` —
  the same batch preset the Quality popover writes — so `recompressState(for:)` and
  `recompressPrediction(for:at:)` re-arm live off `effectivePreset(for:)` rather than a
  second parallel "candidate" preset; every exit that is not a confirmed start (Cancel,
  Escape, the window closing) structurally restores both the previous preset and
  `model.armedExclusions` (the "Choose which files…" popover's own state, snapshotted
  the same way), and a confirm where nothing actually started restores them too.
- Every screen accepts drops, including mid-run (`DragOverlayView` is drawn over
  whatever is underneath) — the drag-during-run path is the reason reservations happen
  at add time.
- `OCRPopover` refuses Fast whenever a CJK language is selected even though
  `QueueViewModel.ocrOptions`' setter already clamps it (`clampingAccuracy`): the
  control must not dangle a choice the model would silently override underneath the
  user.
- A removed row exits through `RowPoof` (squeeze + drift-up + blur + fade,
  `Theme.Motion.rowPoof` = 0.24s — see [DesignSystem](design-system.md)) rather than the plain
  scale-down it used before; Reduce Motion drops to a plain fade with no transform.
- `QueueRow`'s gear (`gearIsMarked`, driven by `differsFromBatch`) and remove-× are now always
  mounted — the gear's slot is reserved and only its opacity/scale animate on hover so the trailing
  size column never shifts sideways, and the remove-× sits at the row's trailing end at rest
  (`textTertiary`, no disc) rather than being hover-inserted (see [DesignSystem](design-system.md)
  `QueueRow`). Only the thumbnail + name open the file now (`RowOpenModifier` moved off the whole
  row onto just those two) — a click in the row's empty middle no longer launches Preview.
- The finished/problems header (`QueueHeaderView`) now carries the same `⊗ Clear` link as the ready
  header, gated on the same `model.canClearFinished` — before this, clearing a finished batch
  required adding more files to reach the Ready screen's Clear.

## Related

- Modules: [App](app.md) (owns the view model, constructs `QueueView`), [Compress](compress.md)
  and [OCR](ocr.md) (the two legs' engine-facing surface), [Shared](shared.md)
  (`ToolQueue`, `FileNaming`), [Models](models.md) (`RowOutcome`, `JobState`),
  [DesignSystem](design-system.md) (`QueueComponents.swift`)
- Specs: `.claude/specs/20260730-ui-redesign.md` §6–§7,
  `.claude/specs/20260725-recompress-quality.md` (the recompress/versions flow)
</content>
