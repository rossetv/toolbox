// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Combine
import Foundation

/// Drives the unified queue (spec §6.1): owns the `ToolQueue`, the verb set (Compress / OCR) and
/// its options, the selected preset/output folder, the per-row overrides, and the engines. It
/// mirrors the queue's jobs so the view re-renders on state changes. Every queued file gets a
/// time-boxed `CompressEstimator` prediction, shown until the real run overtakes it with live
/// progress and a real before/after (both driven by `ToolQueue`'s own `JobState`).
///
/// `ToolQueue.jobs` is the source of truth for lifecycle state (queued/running/done/failed);
/// this view model never mutates it. Instead it publishes its own `jobs` — value-copies of the
/// queue's jobs with the locally-tracked estimate (and an `.analysing` overlay while that
/// estimate is in flight) merged in — so the estimate/analysing bookkeeping stays entirely on
/// this side of the shared `ToolQueue` contract.
///
/// Delivery names are reserved when a file is ADDED, not at run start (spec §6.5) — that is what
/// makes drag-during-run safe, and it is why `ToolQueue.add` no longer needs its own guard.
@MainActor
final class QueueViewModel: ObservableObject {
    @Published var preset: CompressPreset = .balanced {
        didSet {
            guard preset != oldValue else { return }
            // Changing preset is the user saying "never mind that one, what about this?" — a
            // message about the previous target is now stale. Until they do, it stands, ARMED ROW
            // OR NOT: a failed attempt leaves the row armed at the same preset, and suppressing
            // the message there would mean an explicit button press failed silently.
            recompressErrors = [:]
            // Cleared BEFORE the reestimate, which is the only republish this observer needs:
            // `reestimatePendingJobs()`'s whole body is `publishJobs()`, so a trailing call would
            // publish the same state twice.
            reestimatePendingJobs()
        }
    }
    @Published var outputFolder: URL? {
        didSet {
            guard outputFolder != oldValue else { return }
            invalidateReservations()
        }
    }

    // MARK: the verb set (spec §6.1)

    /// The batch verbs. At least one on ⇒ Start enabled; zero ⇒ `canStart` refuses (the chip UI
    /// enforces the same floor visually).
    @Published var compressOn = true {
        didSet {
            guard compressOn != oldValue else { return }
            invalidateReservations()
        }
    }
    @Published var ocrOn = false {
        didSet {
            guard ocrOn != oldValue else { return }
            invalidateReservations()
        }
    }
    /// Language and accuracy for the OCR leg, clamped on write — see `clampingAccuracy`.
    @Published var ocrOptions = OCROptions() {
        didSet {
            let clamped = Self.clampingAccuracy(ocrOptions)
            // Terminates after one extra pass: the clamped value is its own fixed point, so the
            // re-entrant `didSet` this triggers takes the `else` branch and stops.
            if clamped != ocrOptions { ocrOptions = clamped }
        }
    }

    /// Per-row overrides of the batch settings (spec §6.1). Sparse: a row with nothing overridden
    /// has no entry at all, which is the state "Match the batch" restores.
    @Published private(set) var overrides: [ToolJob.ID: RowOverride] = [:]
    /// What add-time inspection found per row (spec §6.6).
    @Published private(set) var inspections: [ToolJob.ID: RowInspection] = [:]
    /// Rows the user has skipped on the Problems screen: excluded from the run and from
    /// `canStart`'s healthy count, but left in the list.
    @Published private(set) var skippedRows: Set<ToolJob.ID> = []
    /// Rows unchecked in Change quality's "Choose which files…" — they report `.none` from
    /// `recompressState` and so never arm (spec §7).
    @Published private(set) var armedExclusions: Set<ToolJob.ID> = []

    // MARK: the scan-rebuild consent queue (spec §7 Scan choice)

    /// Rows whose scan came out two ways and are waiting for the user's choice, oldest first. The
    /// sheet surfaces ONE at a time — the head — and each entry arrives as its own file's delivery
    /// completes, mid-run (spec §7): a batch of scans asks about the first while the rest are still
    /// being compressed, rather than saving every question for the end.
    @Published private(set) var pendingConsents: [ToolJob.ID] = []

    /// "Rebuild scans from now on without asking" (spec §7). Persisted, so the promise outlives the
    /// session that made it: no further sheets, and the REBUILT variant is kept whenever one exists
    /// — the retained descriptor is that evidence, since the engine only retains a variant that
    /// passed validation (F2's retention rule). The versions capsule stays as the undo.
    @Published var rebuildWithoutAsking: Bool {
        didSet {
            guard rebuildWithoutAsking != oldValue else { return }
            defaults.set(rebuildWithoutAsking, forKey: Self.rebuildWithoutAskingKey)
        }
    }
    private static let rebuildWithoutAskingKey = "rebuildScansWithoutAsking"
    private let defaults: UserDefaults

    @Published private(set) var jobs: [ToolJob] = []
    @Published private(set) var isRunning = false
    @Published private(set) var loadError: String?
    /// Rows with a switch in flight: the R10 re-run AND every plain instant swap. Membership is
    /// the re-entrancy/mutual-exclusion guard (`useVersion`, `compress`, `clearFinished`); only
    /// `rerunProgress` drives the busy overlay.
    @Published private(set) var switchesInFlight: Set<ToolJob.ID> = []

    let queue = ToolQueue()
    private let engine: (any Compressing)?
    /// The OCR seam (spec §6.1's absorbed `OCRViewModel`). Injected here so the job body's OCR leg
    /// can be stubbed exactly as the compress leg is; the leg itself is the single-pass task's.
    private let ocrEngine: (any OCRing)?
    private let estimator: CompressEstimator
    private let store: RunnerUpStore
    /// The recent-batches history (spec §6.9). Exposed (not `private`) — `QueueView` holds it as
    /// an `@ObservedObject` of its own (a nested `ObservableObject`'s changes do not propagate
    /// through this view model's own `objectWillChange`), and `RecentBatchesSheet` reads it the
    /// same way. Constructed once, here, and never a second instance.
    let history: HistoryStore
    /// The display authority for every row's versions (R14). Owns the preset each version was
    /// produced at, so a later batch can never rewrite a finished row's preset, and it is the only
    /// path that discards a parked file.
    private let versionStore: VersionStore
    private var cancellable: AnyCancellable?

    /// The preset each in-flight queue job was dispatched at, consumed once when the job's outcome
    /// is ingested into the store. Not display state — the store owns that.
    private var pendingPresets: [ToolJob.ID: CompressPreset] = [:]
    /// What each of a row's files can honestly claim, as the OCR leg found out, held until the
    /// row's versions have been RECORDED: `VersionStore.record` replaces a row wholesale, so a flag
    /// written from the job body would be thrown away by the ingest that follows it. Consumed with
    /// `pendingPresets`, and absent for a row whose OCR leg never ran — which is exactly the state
    /// "no searchability claim in either direction" (spec §6.4).
    private var pendingSearchable: [ToolJob.ID: [VersionCardKey: Bool]] = [:]
    /// Progress fraction for a job in the R10 re-run path, overlaid onto its published state.
    private var rerunProgress: [ToolJob.ID: Double] = [:]
    /// MRC reports produced by an R10 re-run (spec §6's debugging record), overlaid onto the
    /// published job since the re-run bypasses `ToolQueue.run` and never touches `queue.jobs`.
    private var rerunReports: [ToolJob.ID: MRCDocumentReport] = [:]
    /// Rows whose switch could not be honoured, with the message the row shows in place of its
    /// outcome. A row with a retained runner-up states in its capsule which version is on disk and
    /// how big it is; when that claim can no longer be backed — the delivered file is gone, or the
    /// swap left it parked under a hidden name — the row must say so rather than keep labelling a
    /// file that is not there (the F6 mislabel: heavy content under "Normal compression" and gs's
    /// bytes).
    private var switchFailures: [ToolJob.ID: String] = [:]
    /// The in-flight batch's runner-up cache names, snapshotted from the ledger at run start. NOT
    /// the ledger itself: this is the set `cancel` sweeps for FILES the store has not claimed, so
    /// it is scoped to the run and cleared with it, while the reservations themselves are
    /// queue-lifetime and outlive both the cancel and the batch.
    private var runReservations: [ToolJob.ID: URL] = [:]

    /// Every name one row owns. Queue-lifetime (spec §6.5): reserved when the file is ADDED,
    /// recomputed when a mutable input changes while idle, released when the row leaves the queue.
    private struct Reservation: Equatable {
        /// Where this row's single delivered file will land. Optional because a row can ship
        /// nothing at all — the rescue's no-delivery outcomes release it mid-run.
        var delivered: URL?
        /// The runner-up name, reserved only for a row whose compress leg could retain a second
        /// variant. Only a job that actually retains one writes the file; the rest just hold it.
        var alternate: URL?
    }
    private var reservations: [ToolJob.ID: Reservation] = [:]

    /// The batch settings a run locks at its start (spec §6.5). Non-nil for exactly the duration
    /// of a run: every one of that run's jobs — the ones added while it is live included — reads
    /// its destination, verbs and preset from here, so settings the user moves mid-run cannot
    /// retarget work already in flight.
    private struct RunSettings: Equatable {
        let preset: CompressPreset
        let compressOn: Bool
        let ocrOn: Bool
        let folder: URL?
    }
    private var lockedRun: RunSettings?

    /// The settings in force right now: the run's lock while one is in flight, the live values
    /// otherwise. Deliberately one accessor rather than two paths — arming already stands down for
    /// the duration of a run (`recompressState`'s `!isRunning` guard), so the lock cannot distort
    /// anything the user can still act on.
    private var activeSettings: RunSettings {
        lockedRun ?? RunSettings(preset: preset, compressOn: compressOn,
                                 ocrOn: ocrOn, folder: outputFolder)
    }

    /// A recompress attempt that came back with no saving. Dies with the row (Clear finished /
    /// remove) and with the session; never persisted.
    ///
    /// Keyed by the row's effective preset AND its verb set (spec §6.1): a no-gain compress says
    /// nothing about a run that also reads the text, so a verb change must re-open the row rather
    /// than leave it wearing a verdict a different run produced.
    private struct FutileAttempt: Hashable {
        let id: ToolJob.ID
        let preset: CompressPreset
        let compress: Bool
        let ocr: Bool
    }
    private var futileAttempts: Set<FutileAttempt> = []

    private func futileKey(_ id: ToolJob.ID, at preset: CompressPreset) -> FutileAttempt {
        let verbs = effectiveVerbs(for: id)
        return FutileAttempt(id: id, preset: preset, compress: verbs.compress, ocr: verbs.ocr)
    }
    /// Per-row messages that must NOT replace the row's result — the row keeps its result and its
    /// versions and carries the message beside them. Distinct from `switchFailures`, which puts the
    /// row into `.failed` precisely because that row can no longer back what it was claiming.
    @Published private(set) var recompressErrors: [ToolJob.ID: String] = [:]

    /// One armed row's fully-allocated recompress: where it reads from, what it writes into, and
    /// the two cache slots its result may claim. Every path here comes from the up-front serial
    /// reservation pass — nothing is allocated once the concurrent work has started (R11).
    private struct RecompressPlan {
        let id: ToolJob.ID
        let url: URL
        let target: CompressPreset
        /// Where the result is delivered: the row's EXISTING result path, or — for a row that
        /// shipped nothing — a freshly reserved name from the current folder.
        let output: URL
        /// The engine never overwrites, so the result is written here and landed afterwards.
        let temp: URL
        /// The cache slot the version being replaced is parked into.
        let parked: URL
        let runnerUp: URL
    }

    /// Live progress for a row in the direct recompress path, overlaid onto the published job while
    /// `job.state` stays `.done` — the row's displayed state flips only at commit time (R8).
    private var recompressProgress: [ToolJob.ID: Double] = [:]
    // `recompressErrors` already exists (Task 4) and is reused here unchanged: deliberately NOT a
    // `.failed` state, because R12 requires the previous result to stay displayed and openable, so
    // the message rides beside the row's result instead of replacing it.

    /// The phase-2 task group's handle, so an in-flight recompress is cancelled too.
    private var recompressTask: Task<Void, Never>?
    /// Run-scoped cancellation flag, set by `cancel()` and cleared at the START of every run (R9).
    /// Two mechanisms cover the two windows a cancel can land in:
    /// 1. this flag + the guard before phase 2 stops the recompress phase ever STARTING after a
    ///    cancel that landed during phase 1 — `queue.run` returns normally on cancel, so without
    ///    the guard phase 2 begins as if nothing happened;
    /// 2. `recompressTask.cancel()` unwinds recompresses already in flight: it cancels the phase's
    ///    unstructured task, which propagates to its task-group children, so `Task.isCancelled` is
    ///    true inside `recompress` and its `try Task.checkCancellation()` throws before the commit.
    /// The flag is not merely a mirror of `Task.isCancelled`: `await task.value` on a
    /// non-throwing `Task` does not unwind on cancellation, so the explicit guard is load-bearing
    /// rather than decoration.
    private var runCancelled = false
    /// Rows of the current run that have reached a terminal point. A recompress row is `.done`
    /// from beginning to end (R8), so its state cannot carry this. Task 10 reads it for the
    /// progress bar and does NOT re-declare it; this is its single declaration, placed where the
    /// first writer lives.
    private var runCompleted: Set<ToolJob.ID> = []

    /// The rows of the run currently in flight — queued and armed alike. The progress bar's
    /// denominator: a recompress of 2 rows among 5 finished ones must open at 0%, not 60%.
    @Published private(set) var runIDs: [ToolJob.ID] = []

    /// This run's QUEUED rows. Deliberately NOT `runIDs`, which also holds the armed rows: an
    /// armed row is `.done` from beginning to end (R8), so a state-driven sweep over `runIDs`
    /// would count every armed row as finished on the first emission after the run started — a
    /// 1-queued + 1-armed run would open its bar at 50%, the exact failure `runIDs` exists to
    /// prevent. Armed rows are recorded by `recompress` itself, the only thing that knows when
    /// one has genuinely finished.
    private var runQueuedIDs: Set<ToolJob.ID> = []

    /// What the run in flight is made of, captured at its start. Arming is suppressed for the
    /// duration of a run, so the composition cannot be re-derived once it is under way — and the
    /// progress bar's verb ("Compressing" vs "Recompressing") depends on it.
    struct RunComposition: Equatable {
        let queued: Int
        let armed: Int
    }
    @Published private(set) var runComposition = RunComposition(queued: 0, armed: 0)

    // MARK: batch progress + ETA (spec §6.8/§7)

    /// The Working/Finished header's aggregate figures. Persists after the batch ends until the
    /// queue is cleared — `clearFinished()` resets it — because screen 06 reads `savedSoFarBytes`
    /// as its "N MB lighter" headline, the same figure the Working header showed live.
    @Published private(set) var batchProgress: BatchProgress?

    /// One row's active leg (spec §6.8). Compress and OCR each report their OWN raw 0...1
    /// progress; a two-leg row's per-row ring must show ONE continuous fill, never two resets, so
    /// every progress tick is mapped into a sub-range of the composed fraction `job.state`
    /// publishes — the compress leg into `[0, width]`, the OCR leg into `[width, 1]` (or the
    /// whole `[0, 1]` when a row runs only one leg).
    private enum Leg: Equatable { case compress, ocr }

    /// Where a row's CURRENT leg maps into that composed fraction, and when it began. Set exactly
    /// ONCE per leg — never per tick, which would need an actor hop the engines' background-queue
    /// progress callbacks cannot legitimately take (`ToolQueue.process`'s own report closure is the
    /// sanctioned shape for that hop, and it already owns the composed value). `legLabel` and
    /// `rowETASeconds` recover the leg's own raw progress by INVERTING the published composed
    /// fraction against this span — reading the same number the ring shows, never a second one
    /// that could disagree with it.
    private struct LegSpan: Equatable {
        let leg: Leg
        /// Where this leg begins in the composed 0...1 fraction.
        let start: Double
        /// The slice of the composed range this leg owns. Always > 0 — a leg that never runs
        /// never gets a span.
        let width: Double
        let began: Date
    }
    private var legSpans: [ToolJob.ID: LegSpan] = [:]

    /// The even split a two-leg row's composed ring divides into. The exact ratio has no display
    /// consequence beyond where the visible seam falls between the two fills — every other
    /// computation reads the leg's own raw progress, recovered by inverting this same split.
    private static let compressLegWeight = 0.5

    /// This row's own wall-clock start (`runPass`'s first line) and total completed duration,
    /// recorded once — and only once — the queue reports it `.done` (never `.failed`: a failed
    /// row proves nothing about how long finishing would have taken). Renders screen 05's
    /// "finished in 12 seconds".
    private var rowStartTimes: [ToolJob.ID: Date] = [:]
    private var rowDurations: [ToolJob.ID: TimeInterval] = [:]
    /// The compress leg's OWN elapsed time, recorded when it completes — whether or not an OCR
    /// leg follows. `measuredPageRate` divides THIS by page count, never the whole row's
    /// duration: P-B's change-quality preview re-runs compress alone, and OCR (the far slower
    /// leg) would badly over-predict its time if the two were conflated.
    private var compressLegDurations: [ToolJob.ID: TimeInterval] = [:]

    /// The row ids the current (or most recently run) batch is made of. Deliberately NOT `runIDs`:
    /// that resets to empty at the end of `compress()`'s task (see its own doc), which would make
    /// `batchProgress` vanish the instant the batch finishes instead of persisting until the queue
    /// is cleared.
    private var batchRowIDs: Set<ToolJob.ID> = []
    private var batchStartTime: Date?
    /// The ETA smoothing's own running state (`Self.smoothedETA`'s pure arithmetic), reset at
    /// every batch start. Kept here, not on `BatchProgress`, because that type must stay a plain
    /// value snapshot — the smoothing needs to persist ACROSS snapshots.
    private var etaSmoothedRate: Double?
    private var lastDisplayedETASeconds: Int?
    private var lastBatchFraction: Double?

    /// "Reading page N of M" (spec §6.8). `n` is clamped into `1...pageCount`: the job can reach
    /// `.done` a MainActor hop before its state stops being read as `.running` (the same regression
    /// `batchProgressText`'s old clamp test documented), and an unclamped read would print "page 5
    /// of 4". Pure and static so it is directly testable without a live run.
    static func readingPageLabel(rawFraction: Double, pageCount: Int) -> String {
        let n = min(pageCount, max(1, Int((rawFraction * Double(pageCount)).rounded())))
        return "Reading page \(n) of \(pageCount)"
    }

    /// The compress leg's active-meta label (spec §6.8 "per rung"): "Compressing…" while the gs
    /// pass runs, "Rebuilding scan…" once the row's raw compress-leg progress crosses
    /// `CompressEngine.rungProgressCeiling` — the SAME threshold the engine composes its own
    /// progress against, never an independently-guessed one. A row that does not attempt the
    /// rebuild has an effective ceiling of 1.0 (the engine's own `gsProgressCeiling` in that
    /// branch), so `attemptsRebuild: false` reads "Compressing…" throughout — it never crosses a
    /// threshold that, for it, does not exist.
    static func compressLegLabel(rawFraction: Double, attemptsRebuild: Bool) -> String {
        attemptsRebuild && rawFraction >= CompressEngine.rungProgressCeiling
            ? "Rebuilding scan…" : "Compressing…"
    }

    /// A row's own ETA to finish its CURRENT leg — nil before 10% of the LEG's own raw progress
    /// has elapsed (spec §6.8: the gate is per leg, never per batch). Deliberately un-smoothed:
    /// a leg is one short measurement, unlike the batch figure's longer-running rate.
    static func legETASeconds(rawFraction: Double, elapsed: TimeInterval) -> Int? {
        guard rawFraction >= 0.1, elapsed > 0 else { return nil }
        let rate = rawFraction / elapsed
        guard rate > 0 else { return nil }
        return max(0, Int(((1 - rawFraction) / rate).rounded()))
    }

    /// The batch header's ETA (spec §6.8): an exponentially-smoothed completed-fraction rate, nil
    /// before 10%, clamped to never increase while the batch runs ("monotonic display" — a late
    /// slow tick must not make the countdown jump back up). Pure: takes and returns the smoothing
    /// state explicitly rather than mutating instance state, so it is testable without a live run.
    static func smoothedETA(fraction: Double, elapsed: TimeInterval, previousRate: Double?,
                           previousETA: Int?) -> (etaSeconds: Int?, rate: Double?) {
        guard fraction >= 0.1, elapsed > 0 else { return (nil, previousRate) }
        let instantaneous = fraction / elapsed
        guard instantaneous > 0 else { return (nil, previousRate) }
        // A fixed 0.3 weight on the newest reading: enough to track a genuine slowdown/speedup
        // within a few ticks without letting one noisy tick swing the displayed countdown.
        let smoothing = 0.3
        let rate = previousRate.map { smoothing * instantaneous + (1 - smoothing) * $0 } ?? instantaneous
        var seconds = Int(max(0, (1 - fraction) / rate).rounded())
        if let previousETA { seconds = min(seconds, previousETA) }
        return (seconds, rate)
    }

    /// The queue's own jobs, unmodified — `jobs` above is derived from this plus the local
    /// estimate/analysing state below.
    private var rawJobs: [ToolJob] = []
    /// Per-job analysis — every preset's prediction plus the classification behind them, computed
    /// once, so changing preset is a lookup and the recompress prediction (R16) can tell whether
    /// the engine path repeats.
    private var analyses: [UUID: CompressEstimator.Analysis] = [:]
    private var analysingIDs: Set<UUID> = []
    private var estimationTasks: [UUID: Task<Void, Never>] = [:]

    /// Production entry point: resolves the real Ghostscript-backed engine.
    convenience init(estimator: CompressEstimator = CompressEstimator(),
                     store: RunnerUpStore? = nil, history: HistoryStore? = nil) {
        let engine: (any Compressing)?
        let error: String?
        if let runner = try? GhostscriptRunner() {
            engine = CompressEngine(runner: runner)
            error = nil
        } else {
            engine = nil
            error = "Ghostscript is missing from the app bundle — the app cannot compress."
        }
        self.init(engine: engine, ocrEngine: OCREngine(), estimator: estimator, store: store,
                 history: history)
        self.loadError = error
    }

    /// Test seam: inject stub engines (and an override-rooted store) so the queue's legs, the
    /// runner-up switch and the lifecycle can be driven without invoking the real MRC or Vision
    /// pipelines.
    init(engine: (any Compressing)?,
         ocrEngine: (any OCRing)? = OCREngine(),
         estimator: CompressEstimator = CompressEstimator(),
         store: RunnerUpStore? = nil,
         history: HistoryStore? = nil,
         defaults: UserDefaults = .standard) {
        self.engine = engine
        self.ocrEngine = ocrEngine
        self.estimator = estimator
        self.defaults = defaults
        self.rebuildWithoutAsking = defaults.bool(forKey: Self.rebuildWithoutAskingKey)
        // Built here (not as a default argument) because a default value expression is evaluated in
        // a nonisolated context, and `RunnerUpStore.init`/`HistoryStore.init` are `@MainActor`.
        let store = store ?? RunnerUpStore()
        self.store = store
        self.history = history ?? HistoryStore()
        // Sweep anything a previous run left in the cache before this session reserves into it (R15).
        store.sweepStale()
        self.versionStore = VersionStore(cache: store)
        // No `.receive(on:)` hop: `ToolQueue` and this view model are both `@MainActor`, so the
        // publisher already announces synchronously on this actor. Adding a RunLoop hop here
        // previously caused a real bug — Combine's `sink` replays the CURRENT value at
        // subscription time (the empty array from `init`), and `.receive(on: RunLoop.main)`
        // can deliver that stale replay *after* a same-tick `add()` has already scheduled
        // estimates for jobs the stale snapshot doesn't know about yet, so
        // `pruneStaleEstimateState()` wrongly cancelled brand-new estimation tasks. Subscribing
        // synchronously means `rawJobs` is never behind what `queue.jobs` already reflects.
        cancellable = queue.$jobs.sink { [weak self] jobs in
            guard let self else { return }
            self.rawJobs = jobs
            self.ingestCompletedJobs()
            self.recordTerminalRunRows()
            self.recordRowDurations()
            self.pruneStaleEstimateState()
            self.publishJobs()
        }
    }

    /// Move every newly-finished queue job's result into the version store — the one place a
    /// queue-driven outcome becomes display state. `pendingPresets` is consumed here, so this is
    /// idempotent across the many republishes a single batch produces.
    private func ingestCompletedJobs() {
        for job in rawJobs {
            guard case .done(let outcome) = job.state,
                  let preset = pendingPresets[job.id] else { continue }
            pendingPresets[job.id] = nil
            let searchable = pendingSearchable.removeValue(forKey: job.id)
            switch outcome.compress {
            case .compressed(let before, _):
                guard let url = job.resultURL else { continue }
                // `finalBytes`, never the compress leg's `after`: the OCR append grows the file the
                // user actually has, and the commit re-stat'd it (`RowOutcome.finalBytes`' own
                // ownership note). A card showing the pre-append number is the wrong number.
                let shipped = FileVersion(url: url, bytes: outcome.finalBytes, preset: preset,
                                          variant: outcome.shippedVariant ?? .plain)
                // Whether a second version exists is the DESCRIPTOR's answer, never the winner's
                // (spec §5's R7 reversal: keying on which variant shipped is the asymmetry the
                // redesign removes). The parked file's kind comes from the descriptor too — the
                // engine already decided whether it parked the gs output or the untouched input.
                if let retained = outcome.runnerUp {
                    guard let alternate = job.alternateURL else { continue }
                    versionStore.record(RowVersions(originalBytes: before, lastAttemptPreset: preset,
                                                    shipped: shipped,
                                                    runnerUp: FileVersion(url: alternate,
                                                                          bytes: retained.bytes,
                                                                          preset: preset,
                                                                          variant: retained.kind),
                                                    previous: nil),
                                        for: job.id)
                } else {
                    versionStore.record(RowVersions(originalBytes: before, lastAttemptPreset: preset,
                                                    shipped: shipped,
                                                    runnerUp: nil, previous: nil),
                                        for: job.id)
                }
                recordRowProvenance(job, searchable: searchable)
                // Last, and only here: the other two arms ship no compress artefact at all, so
                // neither can hold the pair of scan variants the choice is between.
                surfaceConsent(for: job.id, outcome: outcome)
            case .noGain(let bytes):
                // Nothing shipped, but the attempt still fixes the row's preset (R1). A wholesale
                // `record` is safe here: only `.queued` rows ever reach this path, and a row
                // holding a previous version is `.done` and can never re-enter the queue.
                versionStore.record(RowVersions(originalBytes: bytes, lastAttemptPreset: preset,
                                                shipped: nil, runnerUp: nil, previous: nil),
                                    for: job.id)
                recordRowProvenance(job, searchable: searchable)
                // R6: a first-run no-gain at P0 records (job, P0) as futile exactly as a
                // recompress no-gain does.
                futileAttempts.insert(futileKey(job.id, at: preset))
            case .skipped, nil:
                // A rescued row (spec §6.5) and an OCR-only row deliver a file that carries no
                // compression, so there is no version PAIR to offer and no saving to claim: the
                // row keeps its delivered file through `job.resultURL` and shows "no change".
                continue
            }
        }
    }

    /// The facts only the completed job knows, written onto the row AFTER `record` has replaced its
    /// versions wholesale: where the untouched input lives (the popover's always-present Original
    /// reference row, spec §6.4) and what each of the row's files can honestly claim.
    ///
    /// `setOriginalURL` runs for every recorded row, OCR or not — the reference row is a property of
    /// the row, not of the verb set. A no-gain row records one too: it ships nothing today, but a
    /// later re-run can give it a shipped version, and the reference row must not be missing from
    /// the popover that then appears.
    private func recordRowProvenance(_ job: ToolJob, searchable: [VersionCardKey: Bool]?) {
        versionStore.setOriginalURL(job.url, for: job.id)
        for (card, isSearchable) in searchable ?? [:] {
            versionStore.setSearchable(isSearchable, card: card, for: job.id)
        }
    }

    // MARK: the scan-rebuild consent (spec §7 Scan choice)

    /// Ask about this row's scan — or, when the preference says not to, settle it silently.
    ///
    /// The pair the sheet is about is a REBUILT variant and a plain-compressed one, in either
    /// order: the DESCRIPTOR decides, never which of the two won the size gate (spec §5's R7
    /// reversal — the hybrid that lost is retained exactly as the one that won). The untouched
    /// original park is deliberately not that pair: it exists precisely because the gs candidate
    /// bloated past the input and was withheld (spec §6.3), so there is no "left as photographs,
    /// just lighter" variant to put on a card and no valid gs output for §7's gate to find.
    private func surfaceConsent(for id: ToolJob.ID, outcome: RowOutcome) {
        guard let parked = outcome.runnerUp?.kind else { return }
        // The same normalisation the shipped card is recorded with just above, so the sheet and the
        // popover can never disagree about which variant the delivered file is.
        let shipped = outcome.shippedVariant ?? .plain
        guard (shipped == .mrc && parked == .plain) || (shipped == .plain && parked == .mrc) else {
            return
        }
        guard rebuildWithoutAsking else {
            // One entry per row, never one per delivery: a row whose sheet is still unanswered can
            // be re-run (the quality selector arms it, the consent queue does not block a run), and
            // the sheet reads the row's CURRENT versions — so the waiting entry already asks about
            // the pair this run has just replaced.
            if !pendingConsents.contains(id) { pendingConsents.append(id) }
            return
        }
        // The toggle's promise (spec §7): keep the rebuilt one. Nothing to do when it is already
        // the file the user has — the size gate only ordered the provisional delivery.
        guard shipped != .mrc else { return }
        // The guard is taken HERE, synchronously, and never inside the task: between this sink and
        // the task's first line the batch can end, and `useVersion`'s `!isRunning` guard stops
        // covering a row whose swap has not yet announced itself. A capsule tap landing in that
        // window would run a second `switchVersions` over the same pair, and a `⊗ Clear` would
        // discard the parked file this swap is about to move.
        guard beginSwitch(id) else { return }
        Task { await keepVariant(.mrc, for: id) }
    }

    /// Take the row's switch guard, or refuse because something else already holds it. Every
    /// caller that hands the actual switch to a task must take it in its own synchronous prefix —
    /// a flag set after the first suspension is not a guard (`useVersion`'s note).
    /// `keepVariant`'s `defer` is the one release.
    private func beginSwitch(_ id: ToolJob.ID) -> Bool {
        guard !switchesInFlight.contains(id) else { return false }
        switchesInFlight.insert(id)
        return true
    }

    /// The sheet's two buttons: Keep rebuilt / Keep photographs (spec §7). Both files are already
    /// on disk, so the choice is an instant version switch — which is what makes "nothing is
    /// decided yet" honest right up to this call. `async` because the switch is; the sheet's
    /// buttons call it from a `Task`, exactly as they call `useCard`.
    ///
    /// The row leaves the queue before the switch is attempted: a choice the user has just made
    /// must not re-surface as a sheet if the swap fails. A failure is reported beside the row
    /// instead, and the versions capsule still offers the same switch.
    func resolveConsent(_ id: ToolJob.ID, keepRebuilt: Bool) async {
        pendingConsents.removeAll { $0 == id }
        // Taken before the first suspension, exactly as `useVersion` takes it: two taps on the
        // sheet's buttons must land one switch.
        guard beginSwitch(id) else { return }
        await keepVariant(keepRebuilt ? .mrc : .plain, for: id)
    }

    /// Make `kind` the delivered file, when the row is not already shipping it. The caller holds
    /// the row's `switchesInFlight` membership (`beginSwitch`); this releases it.
    ///
    /// Runs mid-batch on a row whose own delivery is complete and banked, so it relies on that
    /// membership rather than `useVersion`'s `!isRunning` guard: that guard exists to keep a switch
    /// away from a recompress commit for the same row, and this row's work is over. Membership is
    /// also what keeps a later popover switch, and `⊗ Clear`, from interleaving with this one.
    private func keepVariant(_ kind: EngineVariant, for id: ToolJob.ID) async {
        defer { switchesInFlight.remove(id) }
        guard let job = jobs.first(where: { $0.id == id }),
              let row = versions(for: job),
              let shipped = row.shipped, shipped.variant != kind,
              let parked = row.runnerUp, parked.variant == kind else { return }

        do {
            try await store.switchVersions(shipped: shipped.url, runnerUp: parked.url)
            // `swapShipped`, never a bespoke exchange of the two descriptions: it also PERMUTES the
            // searchability flags, and leaving the old flag on the new bytes is exactly the lie
            // spec §6.4 forbids.
            versionStore.swapShipped(with: .runnerUp, for: id)
            recompressErrors[id] = nil
        } catch let stranded as RunnerUpStore.SwitchError {
            // Must precede the generic catch: the delivered file survives under a hidden dot-name
            // nothing else will look for, so the row says where it is (`useVersion`'s reasoning).
            reportSwitchFailure(id, stranded.localizedDescription)
            return
        } catch {
            // The store's contract: any other throw leaves the shipped file exactly as it was, so
            // there is nothing to unwind — only to report. An explicit choice never fails silently
            // (R12), and the version they still have is named so the message is actionable.
            recompressErrors[id] = "Switch failed — kept your "
                                 + "\(shipped.preset.title) version. Try again."
        }
        publishJobs()
    }

    /// Every QUEUED row of this run that has reached a terminal state. Separate from
    /// `ingestCompletedJobs` on purpose: that path is outcome-driven and `.failed` carries no
    /// outcome, so a failure would never be counted and the bar would stall for ever one row
    /// short of 1. Membership is also what keeps rows finished by an EARLIER batch out — they are
    /// `.done` too, and counting them would push `runFinishedCount` past `runIDs.count`.
    private func recordTerminalRunRows() {
        for job in rawJobs where runQueuedIDs.contains(job.id) {
            switch job.state {
            case .done, .failed: runCompleted.insert(job.id)
            case .queued, .analysing, .running: continue
            }
        }
    }

    // MARK: batch progress + ETA (spec §6.8/§7)

    /// This row's total wall-clock time, the instant the queue reports it `.done`. Recorded once
    /// (guarded by `rowDurations[job.id] == nil`) and never for `.failed` — see `rowDurations`'
    /// own doc.
    private func recordRowDurations() {
        for job in rawJobs {
            guard rowDurations[job.id] == nil, let start = rowStartTimes[job.id],
                  case .done = job.state else { continue }
            rowDurations[job.id] = Date().timeIntervalSince(start)
        }
    }

    /// Bytes saved so far: rows whose compress leg actually shipped a smaller file, summed from
    /// `VersionStore` — the display authority — never from `job.state`'s own `RowOutcome`, which
    /// stays the row's ORIGINAL pass outcome for ever once a recompress has landed (R8: a
    /// recompressed row is `.done` throughout, and only `VersionStore` learns of its new size).
    /// A rescue, a noGain and an OCR-only row all record no `shipped` version (spec §6.5) and so
    /// contribute nothing here — never assumed present, always read through the optional.
    private var savedSoFarBytes: Int {
        queue.jobs.reduce(0) { total, job in
            guard let row = versionStore.versions(for: job.id), let shipped = row.shipped else {
                return total
            }
            return total + (row.originalBytes - shipped.bytes)
        }
    }

    // MARK: recent-batches history (spec §6.9)

    /// Record this pass into `history`, reading `lockedRun`/`runQueuedIDs` before `compress()`'s
    /// own tail clears them.
    ///
    /// Scoped ENTIRELY to `runQueuedIDs` — this run's freshly-queued rows — never `batchRowIDs`,
    /// which also holds any armed (recompress) rows: an armed row's `originalBytes - shipped.bytes`
    /// delta is the row's LIFETIME saving, already folded into `lifetimeSavedBytes` by the batch
    /// that first delivered it, so counting it again here on every Change-Quality re-run would
    /// double it. A pass with no freshly-queued rows at all — a pure recompress — is therefore not
    /// a "new batch" in the history sense and records nothing: its own savings are 0 by this same
    /// rule, and spec §6.3 already forbids a "0 MB saved" line.
    private func recordBatchHistory() {
        guard !runQueuedIDs.isEmpty, let settings = lockedRun else { return }
        let jobsByID = Dictionary(uniqueKeysWithValues: queue.jobs.map { ($0.id, $0) })
        var savedBytes = 0
        var searchableCount = 0
        var successCount = 0
        var problem = false
        var partial = false
        for id in runQueuedIDs {
            guard let job = jobsByID[id] else { continue }
            if let sizes = displayedSizes(for: job) {
                // Floored at zero, never subtracted: a row whose OCR append grew the delivered
                // file past the original (`RowOutcome.grew`, spec §6.3) is a real, legitimate row
                // state — but `lifetimeSavedBytes` is a persisted, monotonic "saved since you
                // installed Toolbox" counter, and one grown row must never make it go DOWN by
                // dragging the rest of the batch's genuine savings negative.
                savedBytes += max(0, sizes.before - sizes.after)
            }
            // The "N" in the handoff's "4 of 5 files in Invoices" (F6b) — also stands in for the
            // old `banked` bool below (`successCount > 0` is exactly that check).
            if job.resultURL != nil { successCount += 1 }
            switch job.state {
            case .failed:
                problem = true
            case .done(let outcome):
                if outcome.isDegraded { partial = true }
                if let row = versionStore.versions(for: id) {
                    if row.searchableByCard[.shipped] == true { searchableCount += 1 }
                } else if case .added = outcome.ocr {
                    // No `RowVersions` entry means the compress leg never recorded one at all — a
                    // rescue or a verb-off OCR-only delivery (`ingestCompletedJobs`'s
                    // `case .skipped, nil: continue`). Such a row can NEVER re-arm
                    // (`recompressState`'s `case nil, .skipped: return .none`), so unlike a
                    // compressed row's, `job.state`'s outcome can never go stale for it — the store
                    // has nothing to say, so the outcome IS the truth here.
                    searchableCount += 1
                }
            case .queued, .analysing, .running:
                break
            }
        }
        // A cancelled run with nothing banked leaves no trace (spec §6.9) — the strip and sheet
        // must not show an entry for work that never delivered anything.
        guard !runCancelled || successCount > 0 else { return }
        // `runIDs` lists this run's queued rows before its armed ones, and `runQueuedIDs` is
        // non-empty (guarded above), so its first member here is always a genuinely queued row.
        guard let firstID = runIDs.first(where: { runQueuedIDs.contains($0) }),
              let representative = jobsByID[firstID] else { return }
        // `settings.folder` is the locked save destination; nil resolves the same way
        // `FileNaming.output` resolves a nil folder — beside the first file's own input.
        let folderURL = settings.folder ?? representative.url.deletingLastPathComponent()
        history.record(HistoryBatch(
            folderName: folderURL.lastPathComponent, folderURL: folderURL,
            fileCount: batchRowIDs.count,
            presetTitle: settings.compressOn ? settings.preset.title : nil,
            compressOn: settings.compressOn, ocrOn: settings.ocrOn,
            savedBytes: savedBytes, searchableCount: searchableCount,
            successCount: successCount, failureNote: firstFailureNote(jobsByID: jobsByID),
            partial: partial, problem: problem, cancelled: runCancelled))
    }

    /// The batch card's failure phrase (design screens 01/11, F6b): the FIRST problem row's
    /// condition, in `runIDs` order — never `runQueuedIDs`'s own `Set` order, which is
    /// unspecified. "one was password-locked" is the handoff's own copy; the other two cover
    /// conditions the handoff has no string for, mirroring `RowInspection.metaLine`'s own
    /// `.unreadable`/`.compressFailed` fallthrough — a run-time-only compress failure (OCR off)
    /// never reaches `inspections` at all, so it shares `.unreadable`'s generic phrasing rather
    /// than going unnoted.
    private func firstFailureNote(jobsByID: [ToolJob.ID: ToolJob]) -> String? {
        for id in runIDs where runQueuedIDs.contains(id) {
            guard let job = jobsByID[id], case .failed = job.state else { continue }
            switch inspections[id]?.problem {
            case .locked: return "one was password-locked"
            case .missing: return "one had moved"
            case .unreadable, .compressFailed, .none: return "one couldn't be read"
            }
        }
        return nil
    }

    /// Recompute the published `batchProgress`. Called at the end of every `publishJobs()`; the
    /// smoothing state only advances when the fraction has genuinely changed — `publishJobs()`
    /// re-runs on every queue tick, including ones this batch has nothing to do with, and letting
    /// the ETA's EMA walk on unchanged input would defeat its own monotonic-display guarantee.
    private func updateBatchProgress() {
        // Empty only before the first batch ever ran, or once `clearFinished()` has emptied the
        // queue of every row the last batch touched (`pruneStaleEstimateState`'s sweep) — either
        // way, nothing to show.
        guard !batchRowIDs.isEmpty, let start = batchStartTime else {
            batchProgress = nil
            return
        }
        var completed = 0.0
        for job in jobs where batchRowIDs.contains(job.id) {
            switch job.state {
            case .done, .failed: completed += 1
            case .running(let fraction): completed += fraction
            case .queued, .analysing: break
            }
        }
        let fraction = completed / Double(batchRowIDs.count)
        if fraction != lastBatchFraction {
            let elapsed = Date().timeIntervalSince(start)
            let (eta, rate) = Self.smoothedETA(fraction: fraction, elapsed: elapsed,
                                               previousRate: etaSmoothedRate,
                                               previousETA: lastDisplayedETASeconds)
            etaSmoothedRate = rate
            lastDisplayedETASeconds = eta
            lastBatchFraction = fraction
        }
        batchProgress = BatchProgress(fraction: fraction, etaSeconds: lastDisplayedETASeconds,
                                      savedSoFarBytes: savedSoFarBytes)
    }

    /// Whether this row's compress leg attempts the scan rebuild (Rung 2/3) — mirrors
    /// `CompressEngine`'s own `wantsMRC`/`wantsBilevel` derivation (spec §6.7/F2) from the same
    /// inputs available here: the ESTIMATOR's own analysis, which can legitimately never arrive
    /// (it is time-boxed), never the engine's runtime classification. This is a display label,
    /// not a delivery decision, so an absent analysis just reads as "assume no rebuild" — the
    /// same "Compressing…" a born-digital document gets.
    private func attemptsScanRebuild(for id: ToolJob.ID) -> Bool {
        guard let contentType = analyses[id]?.contentType else { return false }
        if contentType == .scanBilevel { return true }
        return contentType == .scanColour
            && (overrides[id]?.rebuildScan ?? true)
            && effectivePreset(for: id) != .maximumQuality
    }

    /// The compress leg's active-meta line, or "Reading page N of M" during OCR (spec §6.8) — nil
    /// when the row is not currently running.
    func legLabel(for id: ToolJob.ID) -> String? {
        guard case .running(let composed) = jobs.first(where: { $0.id == id })?.state,
              let span = legSpans[id], span.width > 0 else { return nil }
        let raw = min(1, max(0, (composed - span.start) / span.width))
        switch span.leg {
        case .ocr:
            guard let pages = inspections[id]?.pageCount, pages > 0 else { return nil }
            return Self.readingPageLabel(rawFraction: raw, pageCount: pages)
        case .compress:
            return Self.compressLegLabel(rawFraction: raw, attemptsRebuild: attemptsScanRebuild(for: id))
        }
    }

    /// Seconds until this row's CURRENT leg finishes, or nil before 10% of it has elapsed (spec
    /// §6.8's per-leg gate) — recovered by inverting the composed fraction `job.state` already
    /// publishes against the leg's own span, never a second, independently-tracked fraction.
    func rowETASeconds(for id: ToolJob.ID) -> Int? {
        guard case .running(let composed) = jobs.first(where: { $0.id == id })?.state,
              let span = legSpans[id], span.width > 0 else { return nil }
        let raw = min(1, max(0, (composed - span.start) / span.width))
        return Self.legETASeconds(rawFraction: raw, elapsed: Date().timeIntervalSince(span.began))
    }

    /// This row's total processing time, recorded once the queue reports it `.done` — nil for a
    /// row still in flight, still queued, or that ultimately failed (screen 05's "finished in 12
    /// seconds").
    func rowDuration(for id: ToolJob.ID) -> TimeInterval? { rowDurations[id] }

    /// Seconds per page from this row's own completed compress leg (spec §6.7: P-B's change-
    /// quality duration preview derives "about Ns" from the row's own measured run, never a
    /// fabrication). Nil unless the row is `.done`: one that ultimately failed proves nothing
    /// about its compress leg's speed, whatever partial time got recorded for it.
    func measuredPageRate(for id: ToolJob.ID) -> Double? {
        guard case .done = jobs.first(where: { $0.id == id })?.state,
              let duration = compressLegDurations[id],
              let pages = inspections[id]?.pageCount, pages > 0 else { return nil }
        return duration / Double(pages)
    }

    // MARK: effective per-row settings (spec §6.1)

    /// The preset this row will run at: its own override, else the batch's (locked while a run is
    /// in flight). Every preset-keyed structure reads through here — arming, futility, the
    /// displayed estimate and the provenance recorded against the delivered version — so an
    /// overridden row can never be measured against a preset it was not compressed at.
    func effectivePreset(for id: ToolJob.ID) -> CompressPreset {
        overrides[id]?.preset ?? activeSettings.preset
    }

    /// The verbs this row will run, with the per-row floor applied (spec §6.1): an override may
    /// never empty a row's verb set, so an `ocr: false` on a Compress-off batch is refused and the
    /// row keeps its last verb. A batch with no verbs at all is a different rule — `canStart`
    /// refuses it — and manufacturing one here would contradict the disabled Start button.
    func effectiveVerbs(for id: ToolJob.ID) -> (compress: Bool, ocr: Bool) {
        let settings = activeSettings
        let ocr = overrides[id]?.ocr ?? settings.ocrOn
        if !settings.compressOn && !ocr { return (false, settings.ocrOn) }
        return (settings.compressOn, ocr)
    }

    /// Replace one row's overrides; `nil` (or an empty override) is "Match the batch". The row's
    /// reservation follows, because both the delivered suffix and the runner-up name derive from
    /// the row's effective settings (spec §6.5).
    func setOverride(_ override: RowOverride?, for id: ToolJob.ID) {
        let normalised = (override?.isEmpty ?? true) ? nil : override
        guard overrides[id] != normalised else { return }
        let rebuildChanged = (overrides[id]?.rebuildScan ?? true) != (normalised?.rebuildScan ?? true)
        overrides[id] = normalised
        invalidateReservation(for: id)
        // The analysis is cached per FILE but priced against the row's rebuild opt-out (spec
        // §6.7), so a flip must re-price the row — the sibling of the reservation invalidation
        // above. Only a `rebuildScan` change: a preset change is priced from the same analysis
        // (every preset is predicted in one pass), and re-analysing on one would blank the whole
        // list back into its "analysing" state on every click. Unlike the reservation, a row that
        // has already shipped is re-priced too: `recompressPrediction` reads these same estimates
        // for the armed re-run, and a stale rebuild-path figure there is exactly the over-promise
        // the calibration exists to remove.
        if rebuildChanged, !isRunning, let job = queue.jobs.first(where: { $0.id == id }) {
            scheduleEstimate(for: job)
        }
        publishJobs()
    }

    /// Vision's `.fast` recognition covers only the six Latin-script entries of
    /// `OCROptions.curatedLanguages`; Chinese, Japanese and Korean need `.accurate` (recorded on
    /// `OCROptions` itself, read from `supportedRecognitionLanguages()`). A Fast request naming one
    /// of them either fails or reads nothing, so the pairing is clamped at this surface — where the
    /// user can see the control snap back — rather than silently corrected inside the engine.
    private static let accurateOnlyLanguages: Set<String> = ["zh-Hans", "ja-JP", "ko-KR"]

    static func clampingAccuracy(_ options: OCROptions) -> OCROptions {
        guard options.accuracy == .fast,
              options.languages.contains(where: { accurateOnlyLanguages.contains($0) }) else {
            return options
        }
        var clamped = options
        clamped.accuracy = .accurate
        return clamped
    }

    // MARK: the reservation ledger (spec §6.5)

    /// The delivered file's name for a row, or nil when the row has none reserved.
    func reservedDelivery(for id: ToolJob.ID) -> URL? { reservations[id]?.delivered }

    /// The runner-up name for a row, or nil when its effective settings can produce no second
    /// variant.
    func reservedAlternate(for id: ToolJob.ID) -> URL? { reservations[id]?.alternate }

    /// Reserve a fresh delivery name under `suffix`, releasing whatever the row held. The ledger's
    /// ONLY mid-run mutation (spec §6.5's compress-failure rescue and its noGain sibling), and the
    /// reason that switch is race-free: it runs on this actor, through the same allocator every
    /// other reservation uses, so the rescue's `-ocr.pdf` cannot collide with a concurrent add's.
    ///
    /// Returns nil only when the row has left the queue under the caller — the caller then has
    /// nothing to deliver and must fail or abandon that job rather than write to a fabricated name.
    @discardableResult
    func reserveDelivery(suffix: String, for id: ToolJob.ID) -> URL? {
        guard let job = queue.jobs.first(where: { $0.id == id }) else { return nil }
        var keys = reservedKeys(excluding: id)
        // Only the DELIVERY name changes: the row keeps its runner-up reservation, so put that key
        // back before allocating over the top of it.
        if let alternate = reservations[id]?.alternate {
            keys.insert(FileNaming.reservationKey(for: alternate))
        }
        let delivered = FileNaming.output(for: job.url, suffix: suffix,
                                          folder: activeSettings.folder, reserving: &keys)
        reservations[id, default: Reservation()].delivered = delivered
        return delivered
    }

    /// Give up a row's delivery name — the row ships nothing (spec §6.5's `.alreadySearchable` /
    /// `.tooFaint` no-delivery dispositions). Its runner-up reservation is untouched.
    func releaseDelivery(for id: ToolJob.ID) {
        reservations[id]?.delivered = nil
    }

    /// Give up a row's runner-up name too. Paired with `releaseDelivery` on the paths where the
    /// compress leg produced nothing at all — spec §6.5's "BOTH reservations are released" — so a
    /// row that ships nothing holds no name at all.
    func releaseAlternate(for id: ToolJob.ID) {
        reservations[id]?.alternate = nil
    }

    /// Every filename the queue currently owns, as reservation keys.
    ///
    /// Two sources, both load-bearing: the live ledger, and every version a row still holds. The
    /// second is R11's rule — a recompress commit makes the shipped file transiently absent, and
    /// `promote`'s cache-slot step is best-effort, so a row's files can be missing from disk while
    /// the row still owns their paths. The `.originalReference` card is deliberately EXCLUDED: it
    /// names the user's own input file, which no output ever lands on, and seeding it would push
    /// unrelated allocations onto a suffixed name for nothing.
    private func reservedKeys(excluding id: ToolJob.ID? = nil) -> Set<String> {
        var keys: Set<String> = []
        for (rowID, reservation) in reservations where rowID != id {
            if let delivered = reservation.delivered {
                keys.insert(FileNaming.reservationKey(for: delivered))
            }
            if let alternate = reservation.alternate {
                keys.insert(FileNaming.reservationKey(for: alternate))
            }
        }
        for job in queue.jobs {
            for card in versionStore.versions(for: job.id)?.cards ?? []
            where card.key != .originalReference {
                keys.insert(FileNaming.reservationKey(for: card.version.url))
            }
        }
        return keys
    }

    /// Reserve (or re-reserve) every name one row's effective settings can produce.
    ///
    /// The delivered suffix is pinned by spec §6.5: a run including Compress delivers
    /// `-compressed.pdf`, an OCR-only run `-ocr.pdf`. The runner-up name is reserved whenever the
    /// compress leg could retain a second variant — deliberately NOT gated on the content
    /// classification or the preset, because the classification is not known at add time (the
    /// estimator's analysis is async and time-boxed) and an unused reservation costs nothing,
    /// whereas a missing one is the race the ledger exists to close. Only the explicit
    /// `rebuildScan: false` opt-out removes it, because that is the one input the user has already
    /// decided.
    ///
    /// A batch PRESET change is deliberately not an invalidation trigger: it appears nowhere in
    /// §6.5's list, and neither the suffix nor the runner-up name keys on it.
    private func reserve(for job: ToolJob) {
        var keys = reservedKeys(excluding: job.id)
        let verbs = effectiveVerbs(for: job.id)
        let delivered = FileNaming.output(for: job.url,
                                          suffix: verbs.compress ? "compressed" : "ocr",
                                          folder: activeSettings.folder, reserving: &keys)
        let alternate = verbs.compress && overrides[job.id]?.rebuildScan != false
            ? store.reserveURL(for: job.url, reserving: &keys)
            : nil
        reservations[job.id] = Reservation(delivered: delivered, alternate: alternate)
    }

    /// Recompute one row's reservation after a mutable input changed while the queue is idle.
    ///
    /// A row that has already DELIVERED is left alone: its name is the file on disk, so
    /// re-allocating would both hand it a spuriously suffixed name (the allocator skips existing
    /// files) and detach the ledger from `VersionStore.shipped.url`. That is R11's pin-to-the-
    /// existing-result-path rule, in the one new place the ledger could break it.
    private func invalidateReservation(for id: ToolJob.ID) {
        guard !isRunning,
              versionStore.versions(for: id)?.shipped == nil,
              let job = queue.jobs.first(where: { $0.id == id }) else { return }
        reserve(for: job)
    }

    private func invalidateReservations() {
        guard !isRunning else { return }
        for job in queue.jobs { invalidateReservation(for: job.id) }
    }

    var hasQueuedWork: Bool {
        jobs.contains { if case .queued = $0.state { return true } else { return false } }
    }

    var runTotalCount: Int { runIDs.count }
    var runFinishedCount: Int { runCompleted.count }

    var runProgress: Double {
        guard !runIDs.isEmpty else { return 0 }
        var total = Double(runCompleted.count)
        for job in jobs where runIDs.contains(job.id) && !runCompleted.contains(job.id) {
            if case .running(let fraction) = job.state { total += fraction }
        }
        return total / Double(runIDs.count)
    }

    /// Rows waiting to be compressed for the first time (R5's K).
    var pendingCount: Int {
        jobs.filter { job in
            switch job.state {
            case .queued, .analysing: return true
            case .running, .done, .failed: return false
            }
        }.count
    }

    /// Whether Start may run — the one gate `compress()` and the view that offers it must agree on
    /// (CODE_GUIDELINES.md §8.2).
    ///
    /// Two floors beyond the mechanical ones (spec §6.1/§7): zero verbs disables Start outright,
    /// and the queued half of the work must contain at least one HEALTHY row — a file that could
    /// not be opened at add time, or one the user has skipped, is not work this batch can do. Armed
    /// rows count on their own: a re-run of finished rows is a legitimate batch with nothing queued.
    var canStart: Bool {
        engine != nil && !isRunning && switchesInFlight.isEmpty
            && (compressOn || ocrOn)
            && (healthyQueuedCount > 0 || armedCount > 0)
    }

    /// Queued rows this batch could actually work on. A row whose inspection has not landed yet
    /// counts as healthy — the run-time `OpenGuard` pass is the second net, and refusing Start
    /// while a background inspection settles would make the button flicker.
    private var healthyQueuedCount: Int {
        jobs.filter { job in
            switch job.state {
            case .queued, .analysing:
                return inspections[job.id]?.problem == nil && !skippedRows.contains(job.id)
            case .running, .done, .failed:
                return false
            }
        }.count
    }

    /// Whether "Clear finished" may run — the one gate `clearFinished()` and the view that offers
    /// it must agree on (CODE_GUIDELINES.md §8.2), mirroring `canStart`'s shape for its sibling
    /// action.
    var canClearFinished: Bool {
        !isRunning && switchesInFlight.isEmpty && jobs.contains(where: isFinished)
    }

    /// Accepted at any time, a live run included (spec §6.5's drag-during-run). The race the old
    /// `isRunning` guard closed is gone: names are reserved HERE, one row at a time on this actor,
    /// so a row that joins a live batch carries a reserved name exactly like every other row —
    /// against the settings that run locked, never against settings the user has moved since.
    func add(_ urls: [URL]) {
        // `isFileURL` is required, not decorative: a drag can deliver a remote URL (http, ftp),
        // which would otherwise be handed to the engine as if it were a local path.
        let pdfs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return }
        let beforeIDs = Set(queue.jobs.map(\.id))
        queue.add(pdfs)
        for job in queue.jobs where !beforeIDs.contains(job.id) {
            // Serially, one row at a time: each reservation reads the ones already handed out, so
            // two files with the same basename cannot both claim the same name.
            reserve(for: job)
            if isRunning {
                // The row joins the run in flight, so it needs everything `compress()` seeds for
                // the rows that started with it — its provenance and its place in the progress
                // bar's denominator — or it would ingest with no recorded preset and stall the
                // bar one row short of 1.
                pendingPresets[job.id] = effectivePreset(for: job.id)
                runIDs.append(job.id)
                runQueuedIDs.insert(job.id)
                runComposition = RunComposition(queued: runComposition.queued + 1,
                                                armed: runComposition.armed)
            }
            scheduleEstimate(for: job)
            inspect(job)
        }
    }

    /// The Problems screen's Skip: the row stays in the list, untouched, but is excluded from the
    /// run and from `canStart`'s healthy count. Refused mid-run — the run's excluded set is
    /// snapshotted at its start, so a later change could not reach it anyway.
    func setSkipped(_ skipped: Bool, for id: ToolJob.ID) {
        guard !isRunning else { return }
        if skipped { skippedRows.insert(id) } else { skippedRows.remove(id) }
    }

    /// Change quality's "Choose which files…": an unchecked row reports `.none` from
    /// `recompressState`, so it neither arms nor contributes to the armed banner's arithmetic.
    func setArmedExclusion(_ excluded: Bool, for id: ToolJob.ID) {
        guard !isRunning else { return }
        if excluded { armedExclusions.insert(id) } else { armedExclusions.remove(id) }
        publishJobs()
    }

    /// "Find it…" — re-point a row at a file the user has located (spec §7's Problems screen).
    ///
    /// A FULL state reset, not a URL swap: the row is describing a different document, so every
    /// fact the previous file produced goes with it — inspection (and its problem), versions,
    /// futility, the analysis behind its estimate, and any recorded failure. The row's `id`
    /// survives, which is what keeps its overrides and its place in the queue.
    func rebind(_ id: ToolJob.ID, to url: URL) {
        guard !isRunning, url.isFileURL,
              queue.jobs.contains(where: { $0.id == id }) else { return }
        queue.rebind(id, to: url)
        inspections[id] = nil
        skippedRows.remove(id)
        recompressErrors[id] = nil
        switchFailures[id] = nil
        rerunReports[id] = nil
        versionStore.discardRow(id)
        futileAttempts = futileAttempts.filter { $0.id != id }
        // The old file's leg/duration measurements describe a document this row no longer names.
        legSpans[id] = nil
        rowStartTimes[id] = nil
        rowDurations[id] = nil
        compressLegDurations[id] = nil
        // Cleared BEFORE the fresh analysis is scheduled: left standing, the old file's numbers
        // would price the new one until the estimator caught up.
        analyses[id] = nil
        invalidateReservation(for: id)
        guard let job = queue.jobs.first(where: { $0.id == id }) else { return }
        scheduleEstimate(for: job)
        inspect(job)
        publishJobs()
    }

    // MARK: add-time inspection (spec §6.6)

    /// Page count, a text-layer sample and open-failure detection, resolved off the main actor as
    /// files are added. `contentType` is not resolved here — it comes from the estimator's own
    /// time-boxed analysis and is merged in by `scheduleEstimate` when (and if) it lands.
    ///
    /// `OpenGuard`'s run-time inspection stays as the second net: files can move or lock between
    /// add and run, and the Problems screen covers both moments.
    private func inspect(_ job: ToolJob) {
        let url = job.url
        let id = job.id
        Task.detached(priority: .utility) {
            var pageCount: Int?
            var hasTextLayer: Bool?
            var problem: RowProblem?
            do {
                switch try OpenGuard.inspect(url) {
                case .ok(let count):
                    pageCount = count
                    // A SAMPLE, per spec §6.6: the first page answers "does this file read yet?"
                    // without re-parsing the document once per page.
                    hasTextLayer = try? PDFService().pageHasText(url, index: 0)
                case .encrypted:
                    problem = .locked
                case .corrupt:
                    problem = .unreadable
                }
            } catch {
                // `OpenGuard` throws for a file that is not there and for one with no pages at
                // all; only the first is a "moved or renamed" story.
                problem = FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
            }
            let resolved = (pageCount: pageCount, hasTextLayer: hasTextLayer, problem: problem)
            await MainActor.run { [weak self] in
                guard let self, self.queue.jobs.contains(where: { $0.id == id && $0.url == url })
                else { return }   // the row was removed, or rebound onto a different file
                self.inspections[id] = RowInspection(pageCount: resolved.pageCount,
                                                     hasTextLayer: resolved.hasTextLayer,
                                                     contentType: self.analyses[id]?.contentType,
                                                     problem: resolved.problem)
                self.publishJobs()
            }
        }
    }

    func remove(_ job: ToolJob) {
        // Still refused mid-run, unlike `add(_:)`: a recompressing row is `.done` throughout (R8),
        // so a mid-run `remove` would discard a runner-up whose commit is still in flight — the
        // reservation move makes ADDING safe, not removing. The view already never offers removal
        // on such a row, but the invariant belongs to the type that owns the state, not to every
        // caller (CODE_GUIDELINES.md §6.3).
        guard !isRunning else { return }
        // Explicit discard needed here, unlike `clearFinished()`: `ToolQueue.remove(_:)` only
        // actually removes a `.queued` job, so for a `.done`/`.failed` row (the case this method
        // exists for) `queue.remove` below is a no-op on `queue.jobs` — the `pruneStaleEstimateState`
        // sweep that `clearFinished()` can rely on never fires, so the row's parked files would
        // never be discarded without this call.
        versionStore.discardRow(job.id)
        switchFailures[job.id] = nil
        // Same reason again: a pending consent about a row that has left the queue would surface a
        // choice between two files the app has just discarded.
        pendingConsents.removeAll { $0 == job.id }
        // Same reason as the discard above: `queue.remove` is a no-op on a finished row, so the
        // `pruneStaleEstimateState` sweep that would release the ledger entry never fires.
        reservations[job.id] = nil
        queue.remove(job.id)
    }

    func clearFinished() {
        // `canClearFinished` is the one owner of this precondition (CODE_GUIDELINES.md §8.2): a
        // recompressing row is `.done` throughout (R8), so `isFinished`/`removeCompleted` cannot
        // tell it apart from a genuinely finished row, and clearing would discard a runner-up
        // mid-commit; a mid-switch row (ec61602) similarly still displays and queues as `.done`,
        // so clearing would discard the parked file `useVersion`/`rerunForSwitch` is mid-copy
        // into. One coarse guard beats threading an excluded-ids filter through
        // `ToolQueue.removeCompleted()`, which OCR also calls and has no notion of switches (R19).
        guard canClearFinished else { return }
        // No explicit discard loop here either — see `remove(_:)`'s comment: the same
        // `pruneStaleEstimateState()` sweep is the row's one discard path, reached the instant
        // `removeCompleted()` republishes the queue. That sweep also RELEASES the cleared rows'
        // reservations (spec §6.5), so re-adding a same-named file is not pushed onto a suffix by
        // a ledger entry nothing owns any more.
        queue.removeCompleted()
    }

    private func isFinished(_ job: ToolJob) -> Bool {
        switch job.state {
        case .done, .failed: return true
        default: return false
        }
    }

    /// True only when every row has finished AND nothing is armed: an armed row is pending work,
    /// so the success banner, "Reveal in Finder" and "Compress More" must all stand down (R4).
    var allFinished: Bool {
        guard !jobs.isEmpty, !isRunning, armedCount == 0 else { return false }
        return jobs.allSatisfy { job in
            switch job.state {
            case .done, .failed: return true
            case .queued, .analysing, .running: return false
            }
        }
    }

    /// Page count for a job, once add-time inspection has resolved it.
    func pageCount(for job: ToolJob) -> Int? { inspections[job.id]?.pageCount }

    func compress() {
        // Also refused while a switch is in flight: `switchVersions`'s promote is still rewriting
        // the shipped path an outstanding switch owns, and a fresh run here would hand out cache
        // reservations for paths that are transiently absent mid-swap (R9).
        guard let engine, canStart else { return }
        // The run's settings lock here, before anything reads them (spec §6.5): every job of this
        // batch — including any added while it is live — resolves its destination, verb set and
        // preset through `activeSettings`, so a control the user moves mid-run cannot retarget
        // work already in flight.
        lockedRun = RunSettings(preset: preset, compressOn: compressOn,
                                ocrOn: ocrOn, folder: outputFolder)
        // Delivery names are already allocated — every row reserved its own at ADD time (spec
        // §6.5), which is what makes drag-during-run safe. What still has to be allocated here is
        // the RECOMPRESS phase's per-attempt artefacts, so this seeds the same key set the ledger
        // was built against: every live reservation, plus every row's existing versions. That
        // second half is R11's rule — a recompress commit parks then promotes, so the shipped file
        // is transiently absent, and `promote`'s cache-slot step is best-effort, so a `previous`
        // (or `runnerUp`) file can be transiently OR permanently absent while its row still owns
        // that path. Either way an allocation here must be kept off it by the reservation, never
        // by the file happening to exist now.
        var reserved = reservedKeys()
        // Only the rows this batch will actually run: `ToolQueue.execute` picks up `.queued` jobs
        // only, so recording a preset against a finished row from an earlier batch would
        // misattribute it — and a later R10 re-run would rewrite that row's delivered file under a
        // preset it was never compressed at. The preset is the ROW's (spec §6.1): an overridden
        // row records what it actually ran at, or `recompressState` reads it against the wrong one.
        let runnableIDs = queue.jobs
            .filter { isStillQueued($0) && !skippedRows.contains($0.id) }
            .map(\.id)
        for id in runnableIDs { pendingPresets[id] = effectivePreset(for: id) }
        // `armedJobs` is read BEFORE `isRunning` goes true: arming is suppressed for the duration
        // of a run (R9), so the set must be captured while it still exists.
        let armed = armedJobs
        let plans: [RecompressPlan] = armed.map { job in
            let shipped = versionStore.versions(for: job.id)?.shipped
            // R11: the row's own result path, even if "Save to" changed since. A row that shipped
            // nothing (no-gain) has none, so it takes the name it reserved at add time — every row
            // in the queue has one. Allocating a second time from the same `reserved` ledger would
            // collide with the ledger's own entry and hand the row `<name>-compressed-1.pdf`.
            let output = shipped?.url ?? reservedDelivery(for: job.id)
                ?? FileNaming.output(for: job.url, suffix: "compressed",
                                     folder: activeSettings.folder, reserving: &reserved)
            return RecompressPlan(
                id: job.id, url: job.url, target: effectivePreset(for: job.id), output: output,
                temp: output.deletingLastPathComponent()
                    .appendingPathComponent(".toolbox-recompress-\(UUID().uuidString).pdf"),
                parked: versionStore.reservePreviousURL(for: job.url, reserving: &reserved),
                runnerUp: store.reserveURL(for: job.url, reserving: &reserved))
        }
        let queuedIDs = runnableIDs
        // The batch's runner-up names, snapshotted from the ledger for `cancel`'s discard sweep.
        let alternates = Dictionary(uniqueKeysWithValues: queuedIDs.compactMap { id in
            reservations[id]?.alternate.map { (id, $0) }
        })
        let skipped = skippedRows
        runIDs = queuedIDs + plans.map(\.id)
        // The queued subset is tracked separately: see `runQueuedIDs`. An armed row is `.done`
        // throughout, so only `recompress` may mark one finished.
        runQueuedIDs = Set(queuedIDs)
        runComposition = RunComposition(queued: queuedIDs.count, armed: plans.count)
        // Per-run state, cleared at the START of the run: the messages of the run before are stale
        // the moment a new one begins, and the cancel flag must not outlive the run that set it.
        recompressErrors = [:]
        runCompleted = []
        runCancelled = false
        runReservations = alternates
        // `batchRowIDs` — unlike `runIDs` — is deliberately NOT reset when this run ends, so
        // `batchProgress` keeps describing it until `clearFinished()` clears the queue. The
        // smoothing state resets fresh here: a new batch's rate has nothing to do with the last.
        batchRowIDs = Set(runIDs)
        batchStartTime = Date()
        etaSmoothedRate = nil
        lastDisplayedETASeconds = nil
        lastBatchFraction = nil
        isRunning = true
        Task {
            // Phase 1 — the queued rows, through the shared queue: one pass per file, both legs.
            await queue.run({ job, report in
                try await self.runPass(job, engine: engine, report: report)
            }, skipping: skipped)
            // Phase 2 — the armed rows, through the engine directly. SERIALISED after phase 1, not
            // alongside it: running both mechanisms at once would put 2 × the batch width of gs
            // processes on the machine, and the spec bounds the total to one normal batch. One
            // button, one bar, one cancel — and the bound holds by construction (Risk 2).
            // `runRecompressPhase` opens with the `runCancelled` guard, which is what makes a
            // cancel landing during phase 1 stop the run here instead of starting phase 2.
            await runRecompressPhase(plans, engine: engine)
            // Read `lockedRun`/`runQueuedIDs` for the history entry BEFORE the resets below clear
            // them (spec §6.9) — this is the batch's one true "end", reached whether it ran to
            // completion or was cut short by `cancel()`.
            recordBatchHistory()
            // The batch is over: its in-flight runner-up FILES are settled (every committed one is
            // now owned by `versionStore`), so nothing here is `cancel`'s to discard any more. The
            // ledger itself is untouched — reservations are queue-lifetime and outlive the run
            // that used them (spec §6.5).
            runReservations = [:]
            lockedRun = nil
            runIDs = []
            runQueuedIDs = []
            runComposition = RunComposition(queued: 0, armed: 0)
            // Matches the reset above: left uncleared here, `runCompleted` would keep the finished
            // run's ids until the NEXT `compress()` zeroes it at its own start — a stale collection
            // outliving the run it was scoped to.
            runCompleted = []
            isRunning = false
        }
    }

    func cancel() {
        // Set FIRST: `queue.cancel()` can let phase 1 return before the next line runs, and the
        // phase-2 guard reads this flag.
        runCancelled = true
        queue.cancel()          // unwinds the queue's own task
        recompressTask?.cancel()// unwinds recompresses already in flight
        // Discard the in-flight batch's runner-up reservations, except any the store has since
        // claimed as a committed version. A cancelled job returns to `.queued` and, by the engine's
        // atomic-write contract, leaves no partial output — so this only reclaims files a
        // completed-but-superseded job wrote before the cancel landed (R18).
        for (id, url) in runReservations where versionStore.versions(for: id)?.runnerUp?.url != url {
            store.discard(url)
        }
        runReservations = [:]
    }

    // MARK: the single pass (spec §6.2/§6.4/§6.5/§6.8)

    /// What the compress leg left behind for the OCR leg to work with, and the result the row ships
    /// if nothing further happens. Carried as one value because its four fields only ever travel
    /// together — every early return below is `state.result`.
    private struct PassState {
        var outcome: RowOutcome
        /// The file this row delivers, once one exists. A no-gain (or failed) compress leg writes
        /// nothing, so it stays nil until the OCR leg delivers on its own.
        var delivered: URL?
        /// The retained second variant's file — attached whenever the DESCRIPTOR says one was kept,
        /// never keyed on which variant won the gate (spec §5's R7 reversal).
        var runnerUpFile: URL?
        var mrcReport: MRCDocumentReport?

        var result: JobResult {
            JobResult(outcome, outputURL: delivered, alternateURL: runnerUpFile,
                      mrcReport: mrcReport)
        }
    }

    /// One file's whole journey through the queue: compress first (Rungs 2/3 rasterise pages, which
    /// would destroy a pre-existing text layer — spec §6.2), the cancellation boundary, then OCR.
    ///
    /// Runs on this actor inside `ToolQueue`'s task group, so every ledger read and write here is
    /// serialised against every other row's; only the engines leave the actor.
    private func runPass(_ job: ToolJob, engine: any Compressing,
                         report: @escaping @Sendable (Double) -> Void) async throws -> JobResult {
        let verbs = effectiveVerbs(for: job.id)
        var state: PassState
        // The row's own wall-clock start (spec §6.8's "finished in 12 seconds") — set once, here,
        // regardless of which leg(s) this row runs.
        rowStartTimes[job.id] = Date()

        if verbs.compress {
            // Read from the LEDGER, not from a snapshot: a row that joined this batch after it
            // started reserved its name at add time and is in no snapshot taken here. A row with no
            // reservation at all fails loudly rather than silently allocating a second, racing name
            // from inside the concurrent run (see `MissingOutputReservationError`).
            guard let output = reservedDelivery(for: job.id) else {
                throw MissingOutputReservationError()
            }
            let alternate = reservedAlternate(for: job.id)
            // Before the first await, per the concurrency-retrofit lesson: a row launched into a
            // batch that is already cancelling must not start an engine run.
            try Task.checkCancellation()
            var mrcReport: MRCDocumentReport?
            // The compress leg's own composed slice (spec §6.8's continuous per-row fill): the
            // WHOLE range when nothing follows, else the leading half — the OCR leg takes the
            // rest. Captured as plain `Double`s (trivially `Sendable`) so the wrapped `progress`
            // closure below needs no actor hop per tick — only this ONE write, here, is isolated.
            let compressWeight = verbs.ocr ? Self.compressLegWeight : 1.0
            legSpans[job.id] = LegSpan(leg: .compress, start: 0, width: compressWeight, began: Date())
            let compressLegStarted = Date()
            do {
                // The ROW's rebuild decision, never the batch's and never nil: a per-file opt-out
                // that reached the reservation but not the engine would reserve no runner-up name
                // and then produce one (spec §7's per-file settings).
                let outcome = try await engine.compress(job.url,
                                                        preset: effectivePreset(for: job.id),
                                                        to: output, alternateOutput: alternate,
                                                        rebuildScan: overrides[job.id]?.rebuildScan,
                                                        mrcReport: { mrcReport = $0 }) { raw in
                    report(min(1, max(0, raw)) * compressWeight)
                }
                state = PassState(outcome: outcome, mrcReport: mrcReport)
                // Recorded on this, the SUCCESS path, only: a leg that threw (the rescue below)
                // completed nothing, and `measuredPageRate` must never be fed a partial measurement
                // as though it were a genuine one.
                compressLegDurations[job.id] = Date().timeIntervalSince(compressLegStarted)
                switch outcome.compress {
                case .noGain:
                    break       // writes nothing, so there is no output file to point at
                default:
                    state.delivered = output
                    // Attached whenever the DESCRIPTOR says a second variant was retained, never
                    // keyed on which one won the gate (spec §5's R7 reversal).
                    if outcome.runnerUp != nil { state.runnerUpFile = alternate }
                }
            } catch let error as CompressError {
                switch error {
                case .ghostscriptFailed, .validationFailed:
                    // The file is readable — gs or validation failed on it. With the OCR verb on the
                    // row is RESCUED rather than failed (spec §6.5): the compress leg is recorded as
                    // skipped and the read runs against the original. With the verb off there is
                    // nothing to rescue it with.
                    guard verbs.ocr else { throw CompressLegFailure() }
                    let bytes = fileBytes(job.url) ?? 0
                    state = PassState(outcome: RowOutcome(originalBytes: bytes, finalBytes: bytes,
                                                          compress: .skipped(problem: .compressFailed)))
                case .encrypted, .corrupt, .sameInputOutput:
                    // `encrypted`/`corrupt`: OCR would fail identically, so the whole job fails.
                    // `sameInputOutput` is an internal guard and never rescues (spec §6.5's
                    // CompressError partition).
                    throw error
                }
            }
        } else {
            let bytes = fileBytes(job.url) ?? 0
            state = PassState(outcome: RowOutcome(originalBytes: bytes, finalBytes: bytes))
        }

        guard verbs.ocr else { return state.result }
        // The leg boundary. A compress delivery is atomic and complete, so a cancel landing here
        // keeps and banks it — "no partial output" binds WITHIN a leg, never across them — and the
        // row records why it is not searchable rather than reporting no OCR leg at all (spec §6.5).
        // A row that delivered NOTHING has nothing to bank, so it takes the queue's own cancel
        // semantics instead and returns to `.queued`: reporting it finished would mark a file the
        // batch never touched as done, under a caveat about a leg that never ran.
        if Task.isCancelled {
            guard state.delivered != nil else { throw CancellationError() }
            state.outcome.ocr = .cancelled
            return state.result
        }
        return try await runOCRLeg(job, state: state, report: report)
    }

    /// The OCR leg: recognise ONCE from the ORIGINAL — better input than any compressed variant,
    /// and the results serve every variant the job delivers (spec §6.4) — then append the layer to
    /// each of them. Bounded to two files at a time (spec §6.8).
    private func runOCRLeg(_ job: ToolJob, state initial: PassState,
                           report: @escaping @Sendable (Double) -> Void) async throws -> JobResult {
        guard let ocrEngine else { throw MissingOCREngineError() }
        var state = initial
        // The OCR leg's own composed slice — the trailing half when a compress leg ran before it,
        // else the whole range (spec §6.8's continuous per-row fill). `effectiveVerbs` is a pure
        // function of already-current state, so recomputing it here (rather than threading it
        // through as a parameter) costs nothing and stays consistent with `runPass`'s own read.
        let ocrVerbs = effectiveVerbs(for: job.id)
        let ocrStart = ocrVerbs.compress ? Self.compressLegWeight : 0.0
        let ocrWidth = ocrVerbs.compress ? (1.0 - Self.compressLegWeight) : 1.0
        legSpans[job.id] = LegSpan(leg: .ocr, start: ocrStart, width: ocrWidth, began: Date())
        // Whether this leg is the only thing the row will deliver: the compress leg failed (the
        // rescue), found nothing to gain (its sibling), or was never on. Such a file carries no
        // compression, so it ships as `<name>-ocr.pdf` — naming it `-compressed` would be the lie
        // (spec §6.5).
        let destination: URL
        if let compressed = state.delivered {
            destination = compressed
        } else if state.outcome.compress == nil {
            // An OCR-only run reserved `<name>-ocr.pdf` at add time already.
            guard let reserved = reservedDelivery(for: job.id) else {
                throw MissingOutputReservationError()
            }
            destination = reserved
        } else {
            destination = try switchedDelivery(for: job.id)
        }
        // Deliberately derived from the binding above rather than re-tested later: `state.delivered`
        // is assigned as soon as this leg lands its own file, so a second read of it would answer
        // differently half way through.
        let ocrDelivers = state.delivered == nil

        // Two files read at once, whatever the batch width: in-flight 300-DPI rasters plus the
        // recognised runs they produce are already hundreds of megabytes at width 2 (the bound
        // `OCRViewModel` pinned, inherited here with its rationale).
        await acquireOCRSlot()
        defer { releaseOCRSlot() }

        let recognised: RecognisedDocument
        do {
            recognised = try await ocrEngine.recognise(job.url, options: ocrOptions) { raw in
                report(ocrStart + min(1, max(0, raw)) * ocrWidth)
            }
        } catch {
            if ocrDelivers {
                // Nothing was delivered and nothing will be: both names go back and the row fails
                // with the original untouched — the worst case is identical to no rescue at all
                // (spec §6.5).
                releaseDelivery(for: job.id)
                releaseAlternate(for: job.id)
                throw error
            }
            // A read that failed AFTER a compress delivery never fails the job: the file is kept
            // and banked, and the row carries the caveat (spec §7's degraded family). No
            // searchability flags are written — a failed read is evidence of nothing, and a
            // manufactured "not searchable" would be as false as a manufactured "searchable".
            state.outcome.ocr = error is CancellationError
                ? .cancelled
                : .failed(error.localizedDescription)
            return state.result
        }

        state.outcome.ocr = recognised.outcome
        // The Original reference row, and any parked variant that IS the original, are labelled
        // from the OUTCOME (spec §6.4, amended 2026-07-30): the engine returns `.alreadySearchable`
        // only after every page passed `pageHasText`, so that is the one evidence-backed claim. The
        // original itself is never appended to.
        let originalIsSearchable = recognised.outcome == .alreadySearchable
        var flags: [VersionCardKey: Bool] = [.originalReference: originalIsSearchable]

        // Nothing to append, for three reasons the row must not confuse: every page already reads,
        // nothing usable was found, or every recognised run would be destroyed by the WinAnsi text
        // layer this writer emits — a page of `?` that passes every validation and misrepresents
        // the user's document.
        let layerIsUnwritable = Self.layerWouldBeLost(recognised)
        guard case .added = recognised.outcome, !layerIsUnwritable else {
            if ocrDelivers {
                releaseDelivery(for: job.id)
                releaseAlternate(for: job.id)
                // `.alreadySearchable`/`.tooFaint` deliver nothing and take the OCR-only pipeline's
                // own disposition; an unwritable layer had nothing else to hand over, so it fails.
                guard !layerIsUnwritable else { throw UnwritableTextLayerError() }
                return state.result
            }
            flags[.shipped] = false
            if let kind = state.outcome.runnerUp?.kind {
                flags[.runnerUp] = kind == .original ? originalIsSearchable : false
            }
            pendingSearchable[job.id] = flags
            return state.result
        }

        do {
            try await appendLayer(recognised, using: ocrEngine,
                                  reading: ocrDelivers ? job.url : destination,
                                  writing: destination)
            flags[.shipped] = true
            state.delivered = destination
            // Re-stat: the engine reported the COMPRESS artefact's size and the append has just
            // grown the file the user actually gets (`RowOutcome.finalBytes`' ownership note).
            if let bytes = fileBytes(destination) { state.outcome.finalBytes = bytes }
        } catch {
            if ocrDelivers {
                releaseDelivery(for: job.id)
                releaseAlternate(for: job.id)
                throw error
            }
            // A variant that cannot carry the layer is labelled honestly and is never a job failure
            // (spec §6.4): the compress artefact stands exactly as it was delivered.
            flags[.shipped] = false
        }

        if let runnerUpFile = state.runnerUpFile, let kind = state.outcome.runnerUp?.kind {
            if kind == .original {
                flags[.runnerUp] = originalIsSearchable
            } else {
                do {
                    try await appendLayer(recognised, using: ocrEngine,
                                          reading: runnerUpFile, writing: runnerUpFile)
                    flags[.runnerUp] = true
                    // The consent sheet's two cards must be measured at the same moment.
                    if let bytes = fileBytes(runnerUpFile) { state.outcome.runnerUp?.bytes = bytes }
                } catch {
                    flags[.runnerUp] = false
                }
            }
        }
        pendingSearchable[job.id] = flags
        return state.result
    }

    /// Append one variant's copy of the layer. The engine only ever READS `source`, so the result
    /// goes to a temp beside the destination and is landed atomically — replacing the variant when
    /// it is being enriched in place, or arriving as a fresh file when this leg IS the delivery.
    private func appendLayer(_ recognised: RecognisedDocument, using ocrEngine: any OCRing,
                             reading source: URL, writing destination: URL) async throws {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".toolbox-ocr-\(UUID().uuidString).pdf")
        var landed = false
        defer { if !landed { try? FileManager.default.removeItem(at: temp) } }
        // Off the cooperative pool (§6.1): the append writes the whole file and reads it back to
        // validate, and parking a pool thread here would starve every other job in the batch.
        try await offloadBlocking { try ocrEngine.append(recognised, to: source, output: temp) }
        if source == destination {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
        landed = true
    }

    /// Give back the `-compressed` name and take `<name>-ocr.pdf` instead — the ledger's ONE mid-run
    /// mutation (spec §6.5), through the same main-actor allocator every other reservation uses, so
    /// the rescue's name cannot collide with a concurrent add's.
    private func switchedDelivery(for id: ToolJob.ID) throws -> URL {
        guard let url = reserveDelivery(suffix: "ocr", for: id) else {
            throw MissingOutputReservationError()
        }
        return url
    }

    /// True when EVERY recognised run would be destroyed by the WinAnsi encoding `PDFWriter`'s text
    /// layer uses — a CJK, Cyrillic or Greek document, whose layer would land as a page of `?` that
    /// passes every validation while misrepresenting the user's text. Partial loss is deliberately
    /// NOT this: a mixed Latin/CJK page keeps its Latin runs honest, and dropping the layer there
    /// would cost the user real text.
    private static func layerWouldBeLost(_ recognised: RecognisedDocument) -> Bool {
        let runs = recognised.pageText.values.flatMap { $0 }.filter { !$0.text.isEmpty }
        guard !runs.isEmpty else { return false }
        return runs.allSatisfy { PDFWriter.winAnsiWouldLose($0.text) }
    }

    /// A file's size on disk, or nil when it cannot be measured — never a fabricated zero, which
    /// would read as "this file is empty" on a row and flip `RowOutcome.grew` on its own.
    private func fileBytes(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// The OCR leg's two slots (spec §6.8). Main-actor state throughout — every acquire and release
    /// happens on this actor — so the count needs no lock.
    private static let ocrConcurrency = 2
    private var ocrLegsInFlight = 0
    private var ocrLegWaiters: [CheckedContinuation<Void, Never>] = []

    /// Take a slot, suspending until one frees. The wait is deliberately not cancellable: every
    /// holder releases on unwind, so the queue always drains, and a leg resumed after a cancel
    /// simply observes it at its own next checkpoint.
    private func acquireOCRSlot() async {
        if ocrLegsInFlight < Self.ocrConcurrency {
            ocrLegsInFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            ocrLegWaiters.append(continuation)
        }
    }

    /// Hand the slot straight to the next waiter rather than decrementing and re-incrementing — the
    /// gap between the two would let a third leg in ahead of one already queued.
    private func releaseOCRSlot() {
        if ocrLegWaiters.isEmpty {
            ocrLegsInFlight -= 1
        } else {
            ocrLegWaiters.removeFirst().resume()
        }
    }

    // MARK: the direct-engine recompress (R8/R10–R13)

    /// The armed rows, through the engine directly. A sliding window of the same width as a normal
    /// batch, mirroring `ToolQueue.execute` — launch the next as each finishes, never add-all,
    /// which would ignore the cap.
    private func runRecompressPhase(_ plans: [RecompressPlan], engine: any Compressing) async {
        // The gate that makes Cancel work during phase 1. `queue.cancel()` cancels the queue's own
        // task and `queue.run` then returns NORMALLY, so without this the recompress phase would
        // start as though the cancel had never happened — and `recompressTask` is nil for the whole
        // of phase 1, which is why cancelling that alone cannot cover this window.
        guard !runCancelled, !plans.isEmpty else { return }
        let task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var iterator = plans.makeIterator()
                func launchNext() {
                    guard !Task.isCancelled, let plan = iterator.next() else { return }
                    group.addTask { await self?.recompress(plan, engine: engine) }
                }
                for _ in 0..<max(1, SystemInfo.performanceCoreCount) { launchNext() }
                while await group.next() != nil { launchNext() }
            }
        }
        recompressTask = task
        await task.value
        recompressTask = nil
    }

    /// A recompress attempt's two reserved artefacts — `plan.temp` and `plan.runnerUp` — neither of
    /// which was committed. Shared by every exit path of `recompress` and `commit` that leaves
    /// nothing landed: a "can't happen" branch is not a reason to leak a cache file and a
    /// dot-temp for the rest of the session.
    private func discardArtefacts(of plan: RecompressPlan) {
        try? FileManager.default.removeItem(at: plan.temp)
        store.discard(plan.runnerUp)
    }

    /// The OCR leg of the two NON-batch call sites — the quality re-run and the switch re-run
    /// (spec §6.4: "quality re-runs / change-quality regeneration: the regenerated file gets the
    /// layer re-applied"). It is `runOCRLeg`'s sequence with the parts a re-run cannot reach
    /// removed: the compress leg has already delivered, so there is no contingency name to reserve
    /// and no reservation to release, and the row's own file is never at stake.
    ///
    /// Recognises ONCE from the ORIGINAL — better input than any regenerated variant, and the same
    /// runs serve both files — then appends to the regenerated winner and to a retained runner-up,
    /// never to the untouched original, re-stating what it wrote onto `outcome`.
    ///
    /// The returned map is what each regenerated card can honestly claim. An ABSENT key means this
    /// re-run produced no evidence about that file (the verb was off, or the read failed), and the
    /// caller drops the row's old claim rather than carrying it onto new bytes — the flags describe
    /// the BYTES, and a claim inherited from the file this one replaced is the lie §6.4 forbids.
    private func rerunOCRLeg(for id: ToolJob.ID, original: URL, winner: URL, runnerUp: URL?,
                             outcome: inout RowOutcome,
                             report: @escaping @Sendable (Double) -> Void)
        async -> [VersionCardKey: Bool] {
        guard effectiveVerbs(for: id).ocr, let ocrEngine else { return [:] }
        // The trailing half of the row's composed ring — the compress leg took the leading half
        // (`runPass`'s split, which the re-run paths mirror so the row's label and ETA describe the
        // leg actually running rather than the one its last batch left behind).
        let start = Self.compressLegWeight
        let width = 1 - Self.compressLegWeight
        legSpans[id] = LegSpan(leg: .ocr, start: start, width: width, began: Date())
        // The same width-2 bound the batch leg takes: a re-run phase runs one engine call per
        // performance core, and the recognised runs behind each are hundreds of megabytes.
        await acquireOCRSlot()
        defer { releaseOCRSlot() }

        let recognised: RecognisedDocument
        do {
            recognised = try await ocrEngine.recognise(original, options: ocrOptions) { raw in
                report(start + min(1, max(0, raw)) * width)
            }
        } catch {
            // A read that failed never costs the user the file this re-run has already
            // regenerated: it is kept, the row carries the caveat, and no claim is written —
            // a failed read is evidence of nothing (`runOCRLeg`'s own rule).
            outcome.ocr = error is CancellationError
                ? .cancelled
                : .failed(error.localizedDescription)
            return [:]
        }

        outcome.ocr = recognised.outcome
        // Outcome-keyed, exactly as the batch leg labels it (spec §6.4, amended 2026-07-30): the
        // engine returns `.alreadySearchable` only after every page passed `pageHasText`.
        let originalIsSearchable = recognised.outcome == .alreadySearchable
        var flags: [VersionCardKey: Bool] = [.originalReference: originalIsSearchable]
        let retainedKind = outcome.runnerUp?.kind
        // Nothing to append: every page already reads, nothing usable was found, or every
        // recognised run would be destroyed by the WinAnsi text layer this writer emits.
        guard case .added = recognised.outcome, !Self.layerWouldBeLost(recognised) else {
            flags[.shipped] = false
            if let retainedKind {
                flags[.runnerUp] = retainedKind == .original ? originalIsSearchable : false
            }
            return flags
        }

        do {
            try await appendLayer(recognised, using: ocrEngine, reading: winner, writing: winner)
            flags[.shipped] = true
            // Re-stat: the engine reported the COMPRESS artefact's size and the append has just
            // grown the file this row will deliver (`RowOutcome.finalBytes`' ownership note).
            if let bytes = fileBytes(winner) { outcome.finalBytes = bytes }
        } catch {
            // A variant that cannot carry the layer is labelled honestly and is never a failed
            // re-run (spec §6.4): the fresh artefact stands exactly as the engine wrote it.
            flags[.shipped] = false
        }
        if let runnerUp, let retainedKind {
            if retainedKind == .original {
                flags[.runnerUp] = originalIsSearchable      // the original is never appended to
            } else {
                do {
                    try await appendLayer(recognised, using: ocrEngine,
                                          reading: runnerUp, writing: runnerUp)
                    flags[.runnerUp] = true
                    // Both cards are measured at the same moment, as the batch leg measures them.
                    if let bytes = fileBytes(runnerUp) { outcome.runnerUp?.bytes = bytes }
                } catch {
                    flags[.runnerUp] = false
                }
            }
        }
        return flags
    }

    private func recompress(_ plan: RecompressPlan, engine: any Compressing) async {
        let fm = FileManager.default
        // A recompress always reads the ORIGINAL input (D2 — never the compressed output), so a
        // missing original stops this row before it starts; its shipped result and versions stay
        // exactly as they are, and the rest of the batch is unaffected (R10).
        guard fm.fileExists(atPath: plan.url.path) else {
            recompressErrors[plan.id] = "The original file is no longer where it was"
            runCompleted.insert(plan.id)
            publishJobs()
            return
        }
        recompressProgress[plan.id] = 0
        publishJobs()
        let id = plan.id
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.recompressProgress[id] != nil else { return }
                self.recompressProgress[id] = fraction
                self.publishJobs()
            }
        }
        var capturedReport: MRCDocumentReport?
        // The compress leg's own slice of this row's ring: the whole range when nothing follows it,
        // else the leading half — the OCR leg takes the rest (`runPass`'s split).
        let compressWeight = effectiveVerbs(for: plan.id).ocr ? Self.compressLegWeight : 1.0
        legSpans[plan.id] = LegSpan(leg: .compress, start: 0, width: compressWeight, began: Date())
        do {
            // The ROW's rebuild decision, never a hard-coded nil: an opt-out that survives into the
            // row's reservation but not into its re-run would rebuild the very scan the user
            // excluded, the moment they changed quality (spec §7's per-file settings).
            var outcome = try await engine.compress(plan.url, preset: plan.target, to: plan.temp,
                                                    alternateOutput: plan.runnerUp,
                                                    rebuildScan: overrides[plan.id]?.rebuildScan,
                                                    mrcReport: { capturedReport = $0 },
                                                    progress: { raw in
                report(min(1, max(0, raw)) * compressWeight)
            })
            // The engine may return normally after its own final checkpoint (`CompressEngine`'s
            // last `Task.checkCancellation()` precedes the rename-and-return), so a cancel landing
            // in that window arrives here as a successful outcome — committing it would overwrite
            // the file the user already has, which is exactly what R9 forbids.
            try Task.checkCancellation()
            // The layer goes back onto what this run just regenerated (spec §6.4). A no-gain (or
            // skipped) verdict wrote no artefact, so there is nothing to append to and nothing to
            // commit — `commit`'s own arms take those.
            var searchable: [VersionCardKey: Bool] = [:]
            if case .compressed = outcome.compress {
                searchable = await rerunOCRLeg(for: plan.id, original: plan.url, winner: plan.temp,
                                               runnerUp: outcome.runnerUp == nil ? nil : plan.runnerUp,
                                               outcome: &outcome, report: report)
                // The second leg boundary, on the same rule as the first: a cancel that landed
                // inside the read must not reach the commit.
                try Task.checkCancellation()
            }
            try await commit(outcome, plan: plan, report: capturedReport, searchable: searchable)
        } catch is CancellationError {
            // Cancelled. On the throwing path the engine's atomic-write contract left no output;
            // on the post-checkpoint path its result exists at plan.temp (and, when the engine
            // produced one, its alternate at plan.runnerUp) — the two lines below remove both.
            // Nothing was committed either way,
            // so the row keeps its previous result (R9).
            discardArtefacts(of: plan)
        } catch let stranded as RunnerUpStore.SwitchError {
            // MUST precede the generic catch. `shippedStranded` is the one failure where the
            // shipped file is NOT kept — it survives under a hidden dot-name nothing else looks
            // for — so "kept your X version" would be a flat lie about the user's own file.
            // Surface the store's message (it carries the park path) and drop the row's version
            // record, exactly as the switch path does: `reportSwitchFailure` sets
            // `switchFailures[id]`, and `versions(for:)` returns nil while that is set, so the row
            // stops advertising a delivered file it can no longer back (the F6 mislabel).
            discardArtefacts(of: plan)
            reportSwitchFailure(plan.id, stranded.localizedDescription)
        } catch {
            discardArtefacts(of: plan)
            // An explicit button press NEVER fails silently (R12), and the version they kept is
            // named so the message is actionable. Every error reaching here left the shipped file
            // exactly as it was — `promote`'s contract guarantees it for every throw except
            // `shippedStranded`, which the arm above already took. A no-gain row has no shipped
            // file at all (`ingestCompletedJobs`'s `.noGain` arm records `shipped: nil`), so it must
            // not be told it "kept" a version it never received.
            if let kept = versionStore.versions(for: plan.id)?.shipped?.preset {
                recompressErrors[plan.id] = "Recompress failed — kept your \(kept.title) version"
            } else {
                recompressErrors[plan.id] = "Recompress failed — this file is unchanged"
            }
        }
        recompressProgress[plan.id] = nil
        runCompleted.insert(plan.id)
        publishJobs()
    }

    /// R12/R13: land one recompress outcome. The version the user has is parked BEFORE the fresh
    /// result is promoted, so it survives every failure path; a no-gain commits nothing and clears
    /// nothing.
    ///
    /// `async` because the file transfers below must not run on the main actor — see `promote` —
    /// while every state mutation here stays on it, in runs uninterrupted between the awaits. Two
    /// things can now interleave at those awaits and neither changes an outcome: another row's
    /// commit, which touches only its own id and its own pre-reserved paths; and `cancel()`, whose
    /// discard loop walks `runReservations` — the batch's runner-up names, snapshotted from the
    /// ledger at run start — and so
    /// never reaches the separate reservation a plan carries. R9's cancel semantics are unchanged
    /// too: the swap runs on a GCD queue bridged with a checked continuation, which does not inherit
    /// cancellation, so one already begun runs to completion rather than tearing at a `Task`
    /// cancellation — that guarantee does not extend to a crash or quit mid-swap, which can still
    /// strand the shipped file at `performSwap`'s dot-temp, the same accepted residual the engine's
    /// own `destTemp` carries.
    ///
    /// `searchable` is what THIS re-run's OCR leg observed, per card. Every card it regenerated is
    /// relabelled from it, and a card the map has no entry for loses its claim rather than keeping
    /// the replaced file's (`rerunOCRLeg`'s note).
    private func commit(_ outcome: RowOutcome, plan: RecompressPlan,
                        report: MRCDocumentReport?,
                        searchable: [VersionCardKey: Bool]) async throws {
        let fm = FileManager.default
        // Both early returns below are unreachable by construction — a plan is only built for an
        // ARMED row, and `recompressState`'s own `guard let row = versions(for: job)` means a row
        // with no store entry never arms (a no-gain row DOES get an entry, with `shipped: nil`);
        // and `CompressEngine` never returns an outcome without a compress leg — and both clean up
        // anyway: an early return that leaves the temp file and the runner-up reservation behind
        // would leak them for the session, and a "can't happen" is not a reason to leak.
        guard let row = versionStore.versions(for: plan.id) else {
            discardArtefacts(of: plan)
            return
        }
        let shippedBytes: Int
        let variant: EngineVariant
        var runnerUp: FileVersion?
        switch outcome.compress {
        case .compressed:
            // `finalBytes`, never the compress leg's `after`: the OCR leg's append grows the file
            // the user actually receives and re-stats it, and the ingest path records the shipped
            // card from that same number (`RowOutcome.finalBytes`' ownership note). A card showing
            // the pre-append figure is the wrong number.
            shippedBytes = outcome.finalBytes
            // Both facts come from the outcome itself: the winner from `shippedVariant`, and
            // whether anything was parked from the DESCRIPTOR — re-deriving the parked file's kind
            // from its byte count here is how the R7 asymmetry creeps back in (spec §5).
            variant = outcome.shippedVariant ?? .plain
            if let retained = outcome.runnerUp {
                runnerUp = FileVersion(url: plan.runnerUp, bytes: retained.bytes,
                                       preset: plan.target, variant: retained.kind)
            }
        case .noGain:
            // Nothing was written, so there is nothing to commit — and nothing to clear. The
            // shipped version, its URL and its parked versions all stay (R12); the attempt is
            // recorded so re-selecting this preset shows the futile caption rather than re-running
            // a known-futile job (R6).
            discardArtefacts(of: plan)
            futileAttempts.insert(futileKey(plan.id, at: plan.target))
            versionStore.recordAttempt(plan.target, for: plan.id)
            return
        case .skipped, nil:
            // A recompress always runs the compress leg, so neither a skipped leg nor an absent
            // one can reach here — cleaned up regardless, as above.
            discardArtefacts(of: plan)
            return
        }
        if let previouslyShipped = row.shipped, fm.fileExists(atPath: previouslyShipped.url.path) {
            try await store.promote(fresh: plan.temp, to: previouslyShipped.url,
                                    parking: plan.parked)
            // `promote` reaches the cache slot on a best-effort third step (see its doc): a
            // successful return does NOT guarantee a file exists at `plan.parked`. Recording the
            // slot regardless is correct and deliberate — a `previous` slot whose file has gone is
            // an already-designed-for state, handled by `useVersion`'s "That version is no longer
            // available — recompress at <preset> to get it back" path. Nothing below may assume
            // the parked file is on disk.
            // Replacing the previous slot discards the file the old occupant held (R14) — the cache
            // never accumulates superseded versions.
            versionStore.setSlot(.previous,
                                 to: FileVersion(url: plan.parked, bytes: previouslyShipped.bytes,
                                                 preset: previouslyShipped.preset,
                                                 variant: previouslyShipped.variant),
                                 for: plan.id)
            versionStore.setShipped(FileVersion(url: previouslyShipped.url, bytes: shippedBytes,
                                                preset: plan.target, variant: variant),
                                    for: plan.id)
            // The demoted file's claim travels into the slot with it — CARRIED, never recomputed:
            // its bytes have not changed, and this re-run read nothing about them. An absent claim
            // carries across as absent, which also clears whatever the slot's last occupant left.
            versionStore.setSearchable(row.searchableByCard[.shipped], card: .previous, for: plan.id)
        } else {
            // Either the row shipped nothing (no version to park), or it shipped a version whose
            // file was deleted/moved outside the app — `promote`'s first step (`moveItem(at:
            // shipped, to: temp)`) would throw NSFileNoSuchFileError on that file, so there is
            // nothing to park either way. `plan.output` is the row's existing result path when one
            // exists (R11), so the fresh result simply lands there — the recompress succeeded and
            // there is no lie to tell (R12).
            //
            // The destination can already be OCCUPIED even with no shipped version recorded: a
            // no-gain row whose OCR leg delivered holds a real file at the `-ocr.pdf` name it
            // reserved (spec §6.5's noGain sibling), and R11 pins this re-run to that same path —
            // so the fresh result REPLACES it. `moveItem` throws onto an existing destination, and
            // that throw is what turned this row's re-run into "Recompress failed" while its
            // compressed result was discarded.
            // Inline on the main actor, deliberately unlike `promote`: `plan.temp` is allocated in
            // `plan.output`'s own directory, so both calls below are same-volume metadata
            // operations, not the payload I/O `promote`'s off-actor hop exists for.
            if fm.fileExists(atPath: plan.output.path) {
                _ = try fm.replaceItemAt(plan.output, withItemAt: plan.temp)
            } else {
                try fm.moveItem(at: plan.temp, to: plan.output)
            }
            versionStore.setShipped(FileVersion(url: plan.output, bytes: shippedBytes,
                                                preset: plan.target, variant: variant),
                                    for: plan.id)
        }
        versionStore.setSlot(.runnerUp, to: runnerUp, for: plan.id)
        if runnerUp == nil {
            store.discard(plan.runnerUp)
            // A question with one answer is no question: this re-run kept no second variant, so a
            // sheet still queued from the row's earlier delivery would offer a choice between two
            // files when only one now exists.
            pendingConsents.removeAll { $0 == plan.id }
        }
        // Every card this re-run regenerated is relabelled from ITS OWN append result; a card with
        // no entry loses its claim rather than keeping the replaced file's (spec §6.4). The
        // Original reference is the exception in both directions: the file is untouched, so this
        // run's reading of it is written when there is one and its earlier answer stands when
        // there is not.
        versionStore.setSearchable(searchable[.shipped], card: .shipped, for: plan.id)
        versionStore.setSearchable(searchable[.runnerUp], card: .runnerUp, for: plan.id)
        if let original = searchable[.originalReference] {
            versionStore.setSearchable(original, card: .originalReference, for: plan.id)
        }
        if let report { rerunReports[plan.id] = report }
        // R13: a result larger than the version they had still ships — they chose the quality —
        // with honest sizes. The engine guarantees it is smaller than the ORIGINAL; anything else
        // came back `.noGain` above.
        //
        // Last, and only once both descriptions are recorded: the sheet — and the preference's
        // silent keep-rebuilt — read the row's versions, so an earlier call would find half a pair.
        // A re-run's pair is a FRESH choice: the preset selector chooses quality, this sheet
        // chooses how the page looks, and neither answers the other (spec §7).
        surfaceConsent(for: plan.id, outcome: outcome)
    }

    // MARK: per-file estimate

    private func scheduleEstimate(for job: ToolJob) {
        estimationTasks[job.id]?.cancel()
        analysingIDs.insert(job.id)
        publishJobs()
        // The estimator prices every preset in one pass, so the preset half of the rebuild rule
        // is its own; what only this side knows is the row's opt-out (spec §6.7 honesty — a row
        // that will not be rebuilt must not be priced from the rebuild's reduction).
        let mrcEligible = overrides[job.id]?.rebuildScan ?? true

        estimationTasks[job.id] = Task { [weak self] in
            guard let self else { return }
            let analysis = await self.estimator.analyse(job.url, mrcEligible: mrcEligible)
            guard !Task.isCancelled else { return }
            self.analyses[job.id] = analysis
            // Inspection's second pass (spec §6.6): the classification behind the Ready screen's
            // meta line only exists once this analysis lands, and it can legitimately never land
            // (the analysis is time-boxed). The two writes race in either order — the inspection
            // reads `analyses` when it lands first, this patches it when it lands second.
            self.inspections[job.id]?.contentType = analysis.contentType
            self.analysingIDs.remove(job.id)
            self.estimationTasks[job.id] = nil
            self.publishJobs()
        }
    }

    /// Re-run the estimate for every job that hasn't started compressing yet (a preset change
    /// invalidates any prediction made under the old preset).
    /// A preset change needs no new analysis — every preset's prediction was computed when the
    /// file was added, so this is a republish. Re-analysing here is what made the whole list
    /// blank into its "analysing" state on every preset click.
    private func reestimatePendingJobs() {
        publishJobs()
    }

    private func isStillQueued(_ job: ToolJob) -> Bool {
        if case .queued = job.state { return true }
        return false
    }

    /// Drop estimate/analysing bookkeeping for jobs no longer in the queue (e.g. after
    /// `clearFinished()`), so it never grows unbounded across a long session.
    private func pruneStaleEstimateState() {
        let liveIDs = Set(rawJobs.map(\.id))
        analyses = analyses.filter { liveIDs.contains($0.key) }
        analysingIDs = analysingIDs.filter { liveIDs.contains($0) }
        versionStore.retain(only: liveIDs)
        // `pendingPresets` takes over `jobPresets`' in-flight role and, unlike it, is consumed on
        // ingest — but only for a `.done` job. A `.failed` job never reaches `ingestCompletedJobs`'s
        // switch, so its entry is never consumed and would outlive the row without this line.
        // `recompressErrors` is cleared only at the start of the next run and on a preset change,
        // neither of which fires when a row is simply removed.
        pendingPresets = pendingPresets.filter { liveIDs.contains($0.key) }
        pendingSearchable = pendingSearchable.filter { liveIDs.contains($0.key) }
        // The consent sheet renders the HEAD of this list, so an id nothing backs any more would
        // ask about a file that is gone — and `⊗ Clear` reaches rows that are still queued for one.
        pendingConsents = pendingConsents.filter { liveIDs.contains($0) }
        // The reservation ledger is queue-lifetime, so this sweep IS its release path (spec §6.5):
        // a row cleared or removed gives its names straight back, and re-adding a same-named file
        // is not pushed onto `-compressed-1.pdf` by an entry nothing owns any more.
        reservations = reservations.filter { liveIDs.contains($0.key) }
        overrides = overrides.filter { liveIDs.contains($0.key) }
        inspections = inspections.filter { liveIDs.contains($0.key) }
        skippedRows = skippedRows.filter { liveIDs.contains($0) }
        armedExclusions = armedExclusions.filter { liveIDs.contains($0) }
        recompressErrors = recompressErrors.filter { liveIDs.contains($0.key) }
        rerunReports = rerunReports.filter { liveIDs.contains($0.key) }
        switchFailures = switchFailures.filter { liveIDs.contains($0.key) }
        futileAttempts = futileAttempts.filter { liveIDs.contains($0.id) }
        // `switchesInFlight` gates `compress()`/`canCompress`/`clearFinished()` (a416a19/0edc769):
        // an id orphaned here — e.g. a row cleared mid-switch — would leave those refused for the
        // rest of the session even after the re-run's own tail has nothing left to clear it with.
        switchesInFlight = switchesInFlight.filter { liveIDs.contains($0) }
        rerunProgress = rerunProgress.filter { liveIDs.contains($0.key) }
        // Batch progress bookkeeping (spec §6.8): a row cleared or removed carries none of this
        // with it, and `batchRowIDs` emptying out entirely is exactly how `clearFinished()` makes
        // `batchProgress` go back to nil (`updateBatchProgress`'s own guard).
        legSpans = legSpans.filter { liveIDs.contains($0.key) }
        rowStartTimes = rowStartTimes.filter { liveIDs.contains($0.key) }
        rowDurations = rowDurations.filter { liveIDs.contains($0.key) }
        compressLegDurations = compressLegDurations.filter { liveIDs.contains($0.key) }
        batchRowIDs = batchRowIDs.filter { liveIDs.contains($0) }
        for (id, task) in estimationTasks where !liveIDs.contains(id) {
            task.cancel()
            estimationTasks[id] = nil
        }
    }

    /// Rebuild the published `jobs` from `rawJobs` plus the local estimate/analysing overlay.
    /// Never overrides a state the queue has already moved past `.queued` (running/done/failed
    /// stay exactly as the queue reports them).
    private func publishJobs() {
        jobs = rawJobs.map { job in
            var display = job
            // Keyed by the ROW's effective preset (spec §6.1): the batch preset's estimate on an
            // overridden row is two different numbers for one file, so the fix belongs here rather
            // than at each site that renders it.
            display.estimate = analyses[job.id]?.estimates[effectivePreset(for: job.id)]
            if let rerunReport = rerunReports[job.id] { display.mrcReport = rerunReport }
            if let failure = switchFailures[job.id] {
                // Deliberately ahead of the re-run overlay: a failure recorded by the re-run's own
                // tail lands while the id is still in `switchesInFlight`, and the row must show
                // the failure rather than a progress bar for work that has stopped. The row drops
                // its capsule and byte badge with the outcome, which is the point — they described
                // a file that is no longer there.
                display.state = .failed(failure)
            } else if let fraction = recompressProgress[job.id] {
                display.state = .running(fraction)
            } else if let fraction = rerunProgress[job.id] {
                // R10 re-run overlay: the queue still reports the job `.done`, but the switch is
                // re-computing it, so the row shows progress until the re-run lands. Only the
                // genuine engine re-run populates `rerunProgress` (set by `rerunForSwitch`); a
                // plain instant swap only sets `switchesInFlight` as a re-entrancy guard and must
                // keep rendering the row's normal `.done`/`.doneHeavy` state throughout (R4/R7).
                display.state = .running(fraction)
            } else if analysingIDs.contains(job.id), isStillQueued(job) {
                display.state = .analysing
            }
            return display
        }
        updateBatchProgress()
    }

    // MARK: derived arming (R1/R3/R6/R7)

    /// What selecting the current preset means for one finished row (R1/R6/R7). Derived on every
    /// read from the row's versions and futile records — never stored, so re-selecting the row's
    /// own preset disarms it with nothing to unwind (R3).
    enum RowRecompressState: Equatable {
        case none
        /// This row already came back with no saving at that preset; saying so beats re-running it.
        case futile(CompressPreset)
        /// The parked previous version was made at that preset — switch, don't recompute.
        case instantSwitch(CompressPreset)
        /// Will recompress at that preset when the button is pressed.
        case armed(CompressPreset)
    }

    func recompressState(for job: ToolJob) -> RowRecompressState {
        // Nothing arms mid-run: the selector is disabled for the duration (R9), and an armed row
        // whose file is being rewritten underneath it would be describing a moving target.
        guard !isRunning else { return .none }
        // Unchecked in "Choose which files…" — the user has scoped the re-run past this row.
        guard !armedExclusions.contains(job.id) else { return .none }
        guard case .done(let outcome) = job.state else { return .none }
        switch outcome.compress {
        // A `.failed` row never arms (its recourse is re-adding the file), and neither does a row
        // whose compress leg never ran or was skipped — there is nothing to recompress from.
        case nil, .skipped: return .none
        case .compressed, .noGain: break
        }
        // A row whose delivered file could not be backed any more has nothing to recompress from.
        guard let row = versions(for: job) else { return .none }
        // The ROW's preset, not the batch's (spec §6.1): an overridden row is armed against what
        // it would actually run at, and equals the batch preset whenever it overrides nothing.
        let target = effectivePreset(for: job.id)
        // Ahead of the row-preset check on purpose: a row that came back no-gain at its own preset
        // must show the futile caption rather than read as a plain, unremarkable finished row.
        if futileAttempts.contains(futileKey(job.id, at: target)) { return .futile(target) }
        if row.rowPreset == target { return .none }
        if row.previous?.preset == target { return .instantSwitch(target) }
        return .armed(target)
    }

    /// The rows one press would recompress (R5's M).
    var armedJobs: [ToolJob] {
        jobs.filter { if case .armed = recompressState(for: $0) { return true }; return false }
    }

    var armedCount: Int { armedJobs.count }

    // MARK: the armed row's prediction (R16)

    /// The analysis behind a row's estimates — exposed so the prediction's calibration can be
    /// asserted against the same numbers the row displays.
    func analysis(for job: ToolJob) -> CompressEstimator.Analysis? { analyses[job.id] }

    /// R10's arming half: a recompress always reads the ORIGINAL input (D2), so a row whose input
    /// has gone cannot be recompressed at all — and must not advertise a prediction, or offer the
    /// armed pill, as if it could. Checked on every read rather than cached, exactly like the
    /// arming state itself: there is no file watcher, so a stored answer would go stale silently.
    /// The view turns this into the R10 error lead; the model refuses the number.
    ///
    /// At least THREE `stat`s per armed row per body evaluation, not one: `lead(for:)` calls this
    /// directly in its `.armed` arm, then calls `recompressPrediction(for:at:)`, whose first line
    /// calls this again; `armedSummary` (read from body via `model.armedSummary`) calls
    /// `recompressPrediction` once per armed row too, hitting the same guard a third time. Still
    /// bounded by the armed count, not the queue length — every call site is reached only for an
    /// armed row. Not cached, because there is no file watcher to invalidate a stored answer; if
    /// the armed count ever grows large enough for the repeated stats to matter, the fix is a
    /// file-presence watcher, not a stale cache.
    func isOriginalMissing(for job: ToolJob) -> Bool {
        !FileManager.default.fileExists(atPath: job.url.path)
    }

    /// The armed row's predicted size at `target`, or nil when no confident number can be given —
    /// the row then reads "may not shrink" (R16). The "≈" marker is the view's, and stays whatever
    /// this returns: the figure is always approximate.
    ///
    /// The estimator's figure is calibrated by what the engine actually did — but ONLY when the
    /// same path is expected to run again. The path test is the engine's own `wantsMRC`
    /// conjunction, all three terms (`attemptsScanRebuild` reads the same three for the leg
    /// label): the row's `rebuildScan` opt-out, `.scanColour`, and a preset other than
    /// `.maximumQuality`. So an MRC-shipped row crossing to Maximum quality, a gs-shipped row
    /// moving to an MRC-eligible preset, and an MRC-shipped row whose rebuild has since been
    /// turned OFF all change path and take the raw estimate: a ratio learned on one path does not
    /// transfer to the other.
    func recompressPrediction(for job: ToolJob, at target: CompressPreset) -> Int? {
        // Ahead of everything: a confident number for a row that cannot run is the one thing R10
        // names explicitly ("and before arming shows a confident estimate").
        guard !isOriginalMissing(for: job) else { return nil }
        guard let analysis = analyses[job.id],
              let raw = analysis.estimates[target]?.predictedBytes,
              let row = versions(for: job) else { return nil }

        var predicted = raw
        if let shipped = row.shipped,
           // A shipped `.original` is the untouched input, not an engine result — there is no
           // observed ratio in it to calibrate with.
           shipped.variant != .original,
           let baseline = analysis.estimates[shipped.preset]?.predictedBytes, baseline > 0,
           // `contentType` is nil when the analysis timed out or failed — `Analysis`'s own doc
           // says a caller reasoning about the engine path (R16) must not assume one. A shipped
           // `.mrc` variant is only ever produced on a `.scanColour` row, so that gives an
           // effective classification even when the analysis itself came back unknown; otherwise
           // withhold calibration rather than silently reading "unknown" as "not scanColour".
           let classification = analysis.contentType ?? (shipped.variant == .mrc ? .scanColour : nil) {
            let targetWantsMRC = (overrides[job.id]?.rebuildScan ?? true)
                && classification == .scanColour && target != .maximumQuality
            let shippedWasMRC = shipped.variant == .mrc
            if targetWantsMRC == shippedWasMRC {
                predicted = Int((Double(shipped.bytes) / Double(baseline)) * Double(raw))
            }
        }
        // A prediction that does not beat the original is never shown as a confident number.
        guard predicted < row.originalBytes else { return nil }
        return predicted
    }

    /// R4's banner data: how much the armed set is predicted to save on top of what the rows
    /// already shipped. `extraSaving` is summed over armed rows with a CONFIDENT prediction only —
    /// a "may not shrink" row contributes nothing — and is nil when no armed row has one, so the
    /// banner shows no detail line at all rather than a fabricated zero.
    struct ArmedSummary: Equatable {
        let armedCount: Int
        let queuedCount: Int
        let extraSaving: Int?
    }

    var armedSummary: ArmedSummary? {
        let armed = armedJobs
        guard !armed.isEmpty else { return nil }
        var total = 0
        var confident = false
        for job in armed {
            // Each row's own effective preset — the same one it armed against, so the banner's
            // arithmetic and the row's pill can never describe different runs.
            guard let predicted = recompressPrediction(for: job, at: effectivePreset(for: job.id)),
                  let row = versions(for: job) else { continue }
            confident = true
            total += (row.shipped?.bytes ?? row.originalBytes) - predicted
        }
        return ArmedSummary(armedCount: armed.count, queuedCount: pendingCount,
                            extraSaving: confident ? total : nil)
    }

    // MARK: heavy-version switch (R8–R11)

    /// The versions available for `job`, or nil when the row has none to show. A row whose switch
    /// could not be honoured stops advertising versions it can no longer back (the F6 mislabel).
    func versions(for job: ToolJob) -> RowVersions? {
        guard switchFailures[job.id] == nil else { return nil }
        return versionStore.versions(for: job.id)
    }

    /// The before/after byte pair `job` contributes to the batch totals, or nil when the row has
    /// shipped nothing (queued/running/failed/no-gain/OCR). `after` is always the SHIPPED version's
    /// size, so a switch or a recompress keeps the totals in step with the row's own badge.
    func displayedSizes(for job: ToolJob) -> (before: Int, after: Int)? {
        guard let row = versions(for: job), let shipped = row.shipped else { return nil }
        return (row.originalBytes, shipped.bytes)
    }

    /// The versions popover's radio list (design screen 07), one entry point for all four display
    /// keys. The partition is total, and each arm owns its own guarding:
    ///
    /// - `.shipped` is already in use — no guard, no insert, no state change;
    /// - `.runnerUp`/`.previous` delegate to `useVersion`, which checks AND sets `switchesInFlight`
    ///   in its own synchronous prefix. Taking that guard here as well would make every delegated
    ///   switch a silent no-op: a re-entrancy flag set twice is not double safety;
    /// - `.originalReference` is this type's own sequence, and takes the guard itself — no
    ///   `rerunForSwitch` hand-off exists on that path, so nothing else would ever clear it.
    func useCard(_ key: VersionCardKey, for job: ToolJob) async {
        switch key {
        case .shipped: return
        case .runnerUp: await useVersion(.runnerUp, for: job)
        case .previous: await useVersion(.previous, for: job)
        case .originalReference: await useOriginalReference(for: job)
        }
    }

    /// Switch the row back to its untouched input (design screen 07 makes the Original row a radio
    /// target). The original is COPIED — never moved, never appended to, never parked: it stays
    /// exactly where the user keeps it (spec §6.4).
    ///
    /// The copy is landed through `RunnerUpStore.promote`, the recompress commit's own primitive,
    /// rather than a bespoke park-then-copy: promote parks the shipped file FIRST and restores it on
    /// every failure, whereas the naive order lets `setSlot`'s discard delete the displaced previous
    /// version before the copy is even attempted.
    private func useOriginalReference(for job: ToolJob) async {
        guard !isRunning else { return }
        // Checked and set in this synchronous prefix, before the first await — a second tap must
        // observe the guard already taken.
        guard !switchesInFlight.contains(job.id) else { return }
        guard let row = versions(for: job),
              let shipped = row.shipped,
              let originalURL = row.originalURL,
              // Already in use: a second switch would list the original twice and park it over the
              // compressed version the first switch preserved.
              shipped.variant != .original else { return }

        switchesInFlight.insert(job.id)
        defer { switchesInFlight.remove(job.id) }

        let temp = shipped.url.deletingLastPathComponent()
            .appendingPathComponent(".toolbox-original-\(UUID().uuidString).pdf")
        do {
            try FileManager.default.copyItem(at: originalURL, to: temp)
        } catch {
            // Nothing has moved; record nothing. An explicit button press never fails silently
            // (R12), and the version they still have is named so the message is actionable.
            recompressErrors[job.id] = "Switch failed — kept your "
                                     + "\(shipped.preset.title) version. Try again."
            publishJobs()
            return
        }

        var reserved = reservedKeys()
        let parked = versionStore.reservePreviousURL(for: job.url, reserving: &reserved)
        do {
            try await store.promote(fresh: temp, to: shipped.url, parking: parked)
        } catch let stranded as RunnerUpStore.SwitchError {
            // MUST precede the generic catch: the shipped file survives under a hidden dot-name
            // nothing else looks for, so the row states where the file is rather than reporting a
            // switch that quietly cost the user their version.
            try? FileManager.default.removeItem(at: temp)
            reportSwitchFailure(job.id, stranded.localizedDescription)
            return
        } catch {
            // The store's contract: any other throw leaves the shipped file exactly as it was, so
            // there is nothing to unwind and nothing to record.
            try? FileManager.default.removeItem(at: temp)
            recompressErrors[job.id] = "Switch failed — kept your "
                                     + "\(shipped.preset.title) version. Try again."
            publishJobs()
            return
        }

        // `promote` reaches the cache slot on a best-effort third step, so a file may not exist at
        // `parked` — an already-designed-for state (`useVersion`'s "no longer available" path).
        // Replacing the slot discards whatever the old occupant held (R14).
        versionStore.setSlot(.previous,
                             to: FileVersion(url: parked, bytes: shipped.bytes,
                                             preset: shipped.preset, variant: shipped.variant),
                             for: job.id)
        versionStore.setShipped(FileVersion(url: shipped.url, bytes: row.originalBytes,
                                            preset: row.rowPreset, variant: .original),
                                for: job.id)
        // The flags describe the BYTES, so they travel with them — but ONLY when the row has flags
        // at all: on a compress-only row a `?? false` default here would manufacture a claim the
        // row has no evidence for in either direction (spec §6.4).
        if !row.searchableByCard.isEmpty {
            versionStore.setSearchable(row.searchableByCard[.shipped] ?? false,
                                       card: .previous, for: job.id)
            versionStore.setSearchable(row.searchableByCard[.originalReference] ?? false,
                                       card: .shipped, for: job.id)
        }
        recompressErrors[job.id] = nil
        publishJobs()
    }

    /// The popover's switch, and its "Use this" per card. Instant when the parked file still
    /// exists; if the RUNNER-UP has vanished, honestly re-runs the job and applies the requested
    /// switch on completion (R10).
    func useVersion(_ slot: VersionSlot, for job: ToolJob) async {
        // R9's sixth mutating control: a row can still read `.doneHeavy` between `compress()`
        // starting and phase 2 reaching it, so without this guard a switch here could start a
        // second engine run against the same path phase 2's commit is about to drive through
        // `promote` — unserialised, last write wins.
        guard !isRunning else { return }
        // Re-entrancy guard: a second tap (either slot, or the popover's "Use this") before the
        // first switch lands would otherwise interleave two swaps on the same paths off-main-actor.
        // `switchesInFlight` is `@Published`, so inserting/removing it already republishes the
        // view on its own — no `publishJobs()` call is needed purely to reflect membership.
        // Must be checked and set in this synchronous prefix, before the first `await`.
        guard !switchesInFlight.contains(job.id) else { return }
        guard let row = versions(for: job),
              let shipped = row.shipped,
              let parked = slot == .runnerUp ? row.runnerUp : row.previous else { return }

        switchesInFlight.insert(job.id)
        // Cleared before every return except the hand-off to `rerunForSwitch`, which owns clearing
        // it itself once its (possibly still in-flight) work actually finishes. Every other return
        // path below already calls `publishJobs()` for its own reason, so the defer does not need to.
        var handedOffToRerun = false
        defer {
            if !handedOffToRerun {
                switchesInFlight.remove(job.id)
            }
        }

        // Everything below assumes the delivered file is still where this row says it is. If the
        // user deleted or moved it outside the app (there is no file watcher), the re-run tail
        // would quietly re-create it — and, worse, leave the regenerated pair mismatched, so a
        // later switch would ship one version under the other's label and byte count.
        guard FileManager.default.fileExists(atPath: shipped.url.path) else {
            reportSwitchFailure(job.id, "The compressed file is no longer where it was saved, "
                                      + "so there is no version to switch to.")
            return
        }

        if FileManager.default.fileExists(atPath: parked.url.path) {
            do {
                try await store.switchVersions(shipped: shipped.url, runnerUp: parked.url)
                versionStore.swapShipped(with: slot, for: job.id)
                // A retry that succeeds must not leave the previous attempt's failure note beside
                // the row: the view renders `recompressErrors` unconditionally.
                recompressErrors[job.id] = nil
                publishJobs()   // no state moved, but the row's badge/capsule read from the store
                return
            } catch let stranded as RunnerUpStore.SwitchError {
                // The shipped file is parked under a hidden name and nothing else will look for
                // it — re-running would write a new file over the top and bury it for good.
                reportSwitchFailure(job.id, stranded.localizedDescription)
                return
            } catch {
                // The switch did not happen and the shipped file is unchanged (store contract: any
                // other throw restores it). Everything below exists for ONE cause — the parked file
                // raced away — so take it only on evidence. The swap's first step renames the
                // SHIPPED file inside the output folder and never touches the parked one, so a
                // read-only output folder, an immutable flag or an unmounted share throws here with
                // the parked file perfectly intact. Assuming it vanished would drop the version
                // record (whose discard DELETES the file) or burn a re-run over a live runner-up —
                // destroying the one thing D3/R14 promise to keep, over a failure the user can
                // simply retry.
                if FileManager.default.fileExists(atPath: parked.url.path) {
                    recompressErrors[job.id] = "Switch failed — kept your "
                                             + "\(shipped.preset.title) version. Try again."
                    publishJobs()
                    return
                }
            }
        }

        // Only the runner-up can be regenerated: a re-run reproduces the row's OWN preset, which by
        // definition is not the previous version's, so re-running for a vanished PREVIOUS version
        // would hand the user a different file under its label. The shipped result is perfectly
        // fine here — only the parked copy is gone — so this is a message beside the row, never a
        // `.failed` state that would hide a good result.
        guard slot == .runnerUp else {
            versionStore.setSlot(.previous, to: nil, for: job.id)
            recompressErrors[job.id] = "That version is no longer available — recompress at "
                                     + "\(parked.preset.title) to get it back."
            publishJobs()
            return
        }
        // The KIND the user asked for, never a "wants the heavy one" flag: with the R7 asymmetry
        // removed the vanished runner-up is `.mrc`, `.plain` or `.original`, and the re-run's tail
        // maps the regenerated pair onto that kind (spec §5).
        handedOffToRerun = rerunForSwitch(job, wanting: parked.variant)
    }

    /// Record a switch that could not be honoured, so the row reports it instead of continuing to
    /// advertise a version pair it can no longer back.
    private func reportSwitchFailure(_ id: ToolJob.ID, _ message: String) {
        switchFailures[id] = message
        publishJobs()
    }

    /// R10 tail: reached only when the runner-up is genuinely gone — either absent before the swap
    /// was attempted, or confirmed absent by `useVersion`'s re-check after `switchVersions` threw.
    /// Re-run this one job directly through the engine (not the batch queue) to regenerate both
    /// versions, then apply the switch the user asked for. Returns whether it took over the row —
    /// `useVersion` already holds `switchesInFlight` membership for the row (its re-entrancy
    /// guard), so `false` tells the caller it must be the one to clear it.
    private func rerunForSwitch(_ job: ToolJob, wanting kind: EngineVariant) -> Bool {
        // The STORE, never `job.resultURL`/`job.alternateURL`: the queue's record is the first
        // run's and a recompress supersedes it without touching the queue. This tail is only ever
        // reached for a vanished RUNNER-UP (`useVersion` guards `slot == .runnerUp` before
        // calling), so the record still holds both URLs even though the runner-up file is gone —
        // and the runner-up slot is reused in place, so nothing new is reserved here.
        guard let engine,
              let row = versionStore.versions(for: job.id),
              let shipped = row.shipped?.url,
              let runnerUp = row.runnerUp?.url else {
            return false
        }
        let chosen = row.rowPreset
        rerunProgress[job.id] = 0
        publishJobs()

        Task {
            let switched = await regenerateForSwitch(job, engine: engine, shipped: shipped,
                                                     runnerUp: runnerUp, preset: chosen,
                                                     wanting: kind)
            // A retry that succeeds must not leave the previous attempt's failure note beside the
            // row (32380c4); a leg that failed above has just set its own message and must keep it.
            if switched { recompressErrors[job.id] = nil }
            switchesInFlight.remove(job.id)
            rerunProgress[job.id] = nil
            publishJobs()
        }
        return true
    }

    /// The re-run itself: regenerate the row's pair through the engine, re-apply the layer to both
    /// (spec §6.4), record what came back, then apply the switch that was asked for. Returns
    /// whether that switch landed — the caller's tail clears the row's stale failure note on that
    /// answer alone.
    ///
    /// Split out of `rerunForSwitch` so each failure arm can return straight into ONE tail: the
    /// bookkeeping that ends a re-run — the row's guard membership and its progress overlay — has
    /// to run on every path, including the arms that report and stop.
    private func regenerateForSwitch(_ job: ToolJob, engine: any Compressing,
                                     shipped: URL, runnerUp: URL, preset: CompressPreset,
                                     wanting kind: EngineVariant) async -> Bool {
        let id = job.id
        // The one message for "the version you asked for is not there and cannot be made again":
        // the re-run itself succeeded or left the row untouched, so this rides BESIDE the row's
        // result rather than replacing it. An explicit button press never fails silently (R12).
        let unavailable = "That version is no longer available — kept your "
                        + "\(preset.title) version."
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.switchesInFlight.contains(id) else { return }
                self.rerunProgress[id] = fraction
                self.publishJobs()
            }
        }
        // The engine's delivery contract never overwrites an existing destination (it `moveItem`s
        // the winner into place), and `shipped` still holds the pre-rerun file at this point —
        // targeting it directly throws `NSFileWriteFileExistsError`, which the catch below would
        // silently swallow into a no-op switch. So the primary output goes to a fresh,
        // guaranteed-absent temp file instead, landed into `shipped` afterwards.
        let freshShipped = shipped.deletingLastPathComponent()
            .appendingPathComponent(".toolbox-rerun-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: freshShipped) }
        // The runner-up was confirmed absent before this tail was entered, but that check and this
        // re-run are not one atomic step — anything (a sync client, the user) may have put a file
        // back at that path in between. The engine writes the runner-up with a best-effort
        // `copyItem`, which throws (and is swallowed) onto an occupied destination, so a surviving
        // file would stay STALE beside a freshly regenerated winner and the next switch would hand
        // the user one version under the other's label. Clear the slot so the pair matches.
        try? FileManager.default.removeItem(at: runnerUp)
        var capturedReport: MRCDocumentReport?
        // The compress leg's slice of the row's ring, exactly as the batch and quality-re-run paths
        // divide it — a row re-running here shows a label and an ETA for the leg actually in
        // flight, not the one its last batch left behind.
        let compressWeight = effectiveVerbs(for: id).ocr ? Self.compressLegWeight : 1.0
        legSpans[id] = LegSpan(leg: .compress, start: 0, width: compressWeight, began: Date())
        var outcome: RowOutcome
        do {
            // The ROW's rebuild decision, never a hard-coded nil: a row the user excluded from the
            // rebuild must not be rebuilt by a switch it never asked to re-run (spec §7).
            outcome = try await engine.compress(job.url, preset: preset, to: freshShipped,
                                                alternateOutput: runnerUp,
                                                rebuildScan: overrides[id]?.rebuildScan,
                                                mrcReport: { capturedReport = $0 },
                                                progress: { raw in
                report(min(1, max(0, raw)) * compressWeight)
            })
        } catch {
            // Re-run failed; leave the row's prior state untouched (its shipped file survives).
            // The slot still names the file this method deleted, which is what it named on the way
            // in — the row keeps offering a switch the user can retry.
            return false
        }
        // The re-run has to reproduce a PAIR — a second version is the entire reason it ran. A
        // no-gain verdict, or a regeneration that retained nothing, leaves nothing to switch to,
        // and the slot must stop advertising the file deleted above. That the pair came back at
        // all is an engine-determinism assumption the type cannot make for us; WHICH variant won
        // is the descriptor's answer alone (spec §5's R7 reversal), never "the hybrid must have".
        guard case .compressed = outcome.compress, let retained = outcome.runnerUp else {
            versionStore.setSlot(.runnerUp, to: nil, for: id)
            recompressErrors[id] = unavailable
            return false
        }
        let searchable = await rerunOCRLeg(for: id, original: job.url, winner: freshShipped,
                                           runnerUp: runnerUp, outcome: &outcome, report: report)
        do {
            // Land the regenerated winner atomically into the real shipped slot — it was never
            // routed through `shipped` directly (see above) — and only AFTER the append, so the
            // file the user holds is never a half-finished version of itself.
            _ = try FileManager.default.replaceItemAt(shipped, withItemAt: freshShipped)
        } catch {
            // Landing failed; `shipped` is untouched (`replaceItemAt`'s atomic guarantee) so the
            // store's record stays exactly as it was. The engine already wrote the runner-up
            // straight to its slot — orphaned now that there is nothing to switch to, so discard
            // the file and drop the record naming it.
            try? FileManager.default.removeItem(at: runnerUp)
            versionStore.setSlot(.runnerUp, to: nil, for: id)
            recompressErrors[id] = unavailable
            return false
        }
        // The regenerated pair, described from the DESCRIPTOR on both sides: which variant won is
        // `shippedVariant`'s answer, what was parked is the runner-up kind's. The re-run reproduces
        // the row's pair without redefining it, but the BYTES are this run's own — the OCR append
        // has just grown both files. The runner-up keeps its URL, so re-recording the slot
        // discards nothing (`VersionStore`'s documented exception).
        let shippedVariant = outcome.shippedVariant ?? .plain
        versionStore.setShipped(FileVersion(url: shipped, bytes: outcome.finalBytes,
                                            preset: preset, variant: shippedVariant), for: id)
        versionStore.setSlot(.runnerUp,
                             to: FileVersion(url: runnerUp, bytes: retained.bytes,
                                             preset: preset, variant: retained.kind),
                             for: id)
        // Each regenerated file is labelled from its own append; a file this run read nothing about
        // makes no claim at all (spec §6.4, `rerunOCRLeg`'s note).
        versionStore.setSearchable(searchable[.shipped], card: .shipped, for: id)
        versionStore.setSearchable(searchable[.runnerUp], card: .runnerUp, for: id)
        if let original = searchable[.originalReference] {
            versionStore.setSearchable(original, card: .originalReference, for: id)
        }
        rerunReports[id] = capturedReport

        // The switch, mapped onto what actually came back rather than onto what the row used to
        // hold. No consent sheet is queued here, deliberately: the user has just named the variant
        // they want, so there is no choice left to put to them (spec §7's question is which of the
        // two to keep).
        if shippedVariant == kind { return true }   // the winner IS the version they asked for
        guard retained.kind == kind else {
            // A regenerated pair that holds neither: the engine's classification moved under the
            // row (an opt-out, a different preset path), so the requested version genuinely cannot
            // be produced any more. The pair on disk is canonical and stays.
            recompressErrors[id] = unavailable
            return false
        }
        do {
            try await store.switchVersions(shipped: shipped, runnerUp: runnerUp)
            versionStore.swapShipped(with: .runnerUp, for: id)
            return true
        } catch let stranded as RunnerUpStore.SwitchError {
            // The regenerated winner is parked under a hidden name that nothing else looks for —
            // the row must name it, not report a switch that silently cost the user their file.
            reportSwitchFailure(id, stranded.localizedDescription)
        } catch {
            // The switch did not happen and `shipped` is unchanged (store contract: any other
            // throw restores it), so the store's record stays canonical rather than describing a
            // switch that never took effect — and says so (R12).
            recompressErrors[id] = "Switch failed — kept your \(preset.title) version. Try again."
        }
        return false
    }
}

/// A compress-specific failure (`ghostscriptFailed`/`validationFailed`) on a row whose OCR verb is
/// OFF: there is no second leg to rescue it with, so the row fails (spec §6.5). The handoff has no
/// string for this state — a recorded copy divergence owned by the queue.
struct CompressLegFailure: LocalizedError {
    var errorDescription: String? { "Couldn't be compressed" }
}

/// Every recognised run would be destroyed by `PDFWriter`'s WinAnsi text layer, and this row had
/// nothing but that layer to deliver. Skipping the append is the honest answer everywhere (spec
/// §6.4's label rule); with no compress artefact to fall back on there is simply nothing to hand
/// over, so the row fails saying why.
struct UnwritableTextLayerError: LocalizedError {
    var errorDescription: String? {
        "The text in this file uses characters Toolbox can't add to a PDF yet."
    }
}

/// The OCR verb was on for a row but no OCR engine was injected. Only reachable through the test
/// seam — production always resolves one — and the row fails loudly rather than silently dropping
/// a verb the user asked for.
struct MissingOCREngineError: LocalizedError {
    var errorDescription: String? { "The text reader is unavailable." }
}

/// The compression capability `QueueViewModel` depends on — a seam so tests can stub the engine
/// without invoking the real MRC pipeline. `CompressEngine` is the sole production implementation.
/// `Sendable` because the job body that calls it is handed to `ToolQueue`'s task group.
protocol Compressing: Sendable {
    func compress(_ input: URL,
                  preset: CompressPreset,
                  to output: URL,
                  alternateOutput: URL?,
                  rebuildScan: Bool?,
                  mrcReport: ((MRCDocumentReport) -> Void)?,
                  progress: @escaping (Double) -> Void) async throws -> RowOutcome
}

extension CompressEngine: Compressing {}
