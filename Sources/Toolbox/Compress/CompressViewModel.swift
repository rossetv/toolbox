// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Combine
import Foundation

/// Drives the Compress tool: owns the `ToolQueue`, the selected preset/output folder and the
/// Rung-1 `CompressEngine`, and mirrors the queue's jobs so the view re-renders on state
/// changes. Batch (Track C, Task C.2): every queued file gets a time-boxed `CompressEstimator`
/// prediction, shown until the real compress run overtakes it with live progress and a real
/// before/after (both driven by `ToolQueue`'s own `JobState`).
///
/// `ToolQueue.jobs` is the source of truth for lifecycle state (queued/running/done/failed);
/// this view model never mutates it. Instead it publishes its own `jobs` — value-copies of the
/// queue's jobs with the locally-tracked estimate (and an `.analysing` overlay while that
/// estimate is in flight) merged in — so the estimate/analysing bookkeeping stays entirely on
/// this side of the shared `ToolQueue` contract.
@MainActor
final class CompressViewModel: ObservableObject {
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
    @Published var outputFolder: URL?
    @Published private(set) var jobs: [ToolJob] = []
    /// Page count per job, resolved off the main actor as files are added.
    @Published private(set) var pageCounts: [ToolJob.ID: Int] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var loadError: String?
    /// Rows with a switch in flight: the R10 re-run AND every plain instant swap. Membership is
    /// the re-entrancy/mutual-exclusion guard (`useVersion`, `compress`, `clearFinished`); only
    /// `rerunProgress` drives the busy overlay.
    @Published private(set) var switchesInFlight: Set<ToolJob.ID> = []

    let queue = ToolQueue()
    private let engine: (any Compressing)?
    private let estimator: CompressEstimator
    private let store: RunnerUpStore
    /// The display authority for every row's versions (R14). Owns the preset each version was
    /// produced at, so a later batch can never rewrite a finished row's preset, and it is the only
    /// path that discards a parked file.
    private let versionStore: VersionStore
    private var cancellable: AnyCancellable?

    /// The preset each in-flight queue job was dispatched at, consumed once when the job's outcome
    /// is ingested into the store. Not display state — the store owns that.
    private var pendingPresets: [ToolJob.ID: CompressPreset] = [:]
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
    /// Runner-up cache names reserved for the in-flight batch. A run-scoped RESERVATION ledger, not
    /// a version record: a reservation whose job never shipped a runner-up is discarded by `cancel`
    /// and by the run's own teardown, and everything committed is owned by `versionStore`.
    private var runReservations: [ToolJob.ID: URL] = [:]
    /// A recompress attempt that came back with no saving. Dies with the row (Clear finished /
    /// remove) and with the session; never persisted.
    private struct FutileAttempt: Hashable {
        let id: ToolJob.ID
        let preset: CompressPreset
    }
    private var futileAttempts: Set<FutileAttempt> = []
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
                     store: RunnerUpStore? = nil) {
        let engine: (any Compressing)?
        let error: String?
        if let runner = try? GhostscriptRunner() {
            engine = CompressEngine(runner: runner)
            error = nil
        } else {
            engine = nil
            error = "Ghostscript is missing from the app bundle — the app cannot compress."
        }
        self.init(engine: engine, estimator: estimator, store: store)
        self.loadError = error
    }

    /// Test seam: inject a stub engine (and an override-rooted store) so the runner-up switch and
    /// lifecycle can be driven without invoking the real MRC pipeline.
    init(engine: (any Compressing)?,
         estimator: CompressEstimator = CompressEstimator(),
         store: RunnerUpStore? = nil) {
        self.engine = engine
        self.estimator = estimator
        // Built here (not as a default argument) because a default value expression is evaluated in
        // a nonisolated context, and `RunnerUpStore.init` is `@MainActor`.
        let store = store ?? RunnerUpStore()
        self.store = store
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
            switch outcome.compress {
            case .compressed(let before, let after):
                guard let url = job.resultURL else { continue }
                let shipped = FileVersion(url: url, bytes: after, preset: preset,
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
            case .noGain(let bytes):
                // Nothing shipped, but the attempt still fixes the row's preset (R1). A wholesale
                // `record` is safe here: only `.queued` rows ever reach this path, and a row
                // holding a previous version is `.done` and can never re-enter the queue.
                versionStore.record(RowVersions(originalBytes: bytes, lastAttemptPreset: preset,
                                                shipped: nil, runnerUp: nil, previous: nil),
                                    for: job.id)
                // R6: a first-run no-gain at P0 records (job, P0) as futile exactly as a
                // recompress no-gain does.
                futileAttempts.insert(FutileAttempt(id: job.id, preset: preset))
            case .skipped:
                continue        // the compress leg never runs alone here; the rescue is spec §6.5's
            case nil:
                continue        // no compress leg — never produced by CompressEngine
            }
        }
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

    var canCompress: Bool {
        engine != nil && !isRunning && switchesInFlight.isEmpty && (hasQueuedWork || armedCount > 0)
    }

    /// Whether "Clear finished" may run — the one gate `clearFinished()` and the view that offers
    /// it must agree on (CODE_GUIDELINES.md §8.2), mirroring `canCompress`'s shape for its sibling
    /// action.
    var canClearFinished: Bool {
        !isRunning && switchesInFlight.isEmpty && jobs.contains(where: isFinished)
    }

    func add(_ urls: [URL]) {
        // Gated on `isRunning`: `compress()` snapshots `queue.jobs` and reserves an output name for
        // each up front, but several MainActor hops separate that snapshot from the queue actually
        // launching jobs. A file added in that window would be `.queued` and run by the live batch
        // with no reserved name — the very race `outputs`/`reserved` exist to prevent.
        guard !isRunning else { return }
        // `isFileURL` is required, not decorative: a drag can deliver a remote URL (http, ftp),
        // which would otherwise be handed to the engine as if it were a local path.
        let pdfs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return }
        let beforeIDs = Set(queue.jobs.map(\.id))
        queue.add(pdfs)
        for job in queue.jobs where !beforeIDs.contains(job.id) {
            scheduleEstimate(for: job)
        }
        resolvePageCounts()
    }

    func remove(_ job: ToolJob) {
        // Matches `add(_:)`'s guard: a recompressing row is `.done` throughout (R8), so a mid-run
        // `remove` would discard a runner-up whose commit is still in flight. The view already
        // never offers removal on such a row, but the invariant belongs to the type that owns the
        // state, not to every caller (CODE_GUIDELINES.md §6.3).
        guard !isRunning else { return }
        // Explicit discard needed here, unlike `clearFinished()`: `ToolQueue.remove(_:)` only
        // actually removes a `.queued` job, so for a `.done`/`.failed` row (the case this method
        // exists for) `queue.remove` below is a no-op on `queue.jobs` — the `pruneStaleEstimateState`
        // sweep that `clearFinished()` can rely on never fires, so the row's parked files would
        // never be discarded without this call.
        versionStore.discardRow(job.id)
        switchFailures[job.id] = nil
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
        // `removeCompleted()` republishes the queue.
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

    /// Page count for a job, once resolved.
    func pageCount(for job: ToolJob) -> Int? { pageCounts[job.id] }

    private func resolvePageCounts() {
        let pending = queue.jobs.filter { pageCounts[$0.id] == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) {
            let service = PDFService()
            for job in pending {
                guard let count = try? service.pageCount(job.url) else { continue }
                await MainActor.run { self.pageCounts[job.id] = count }
            }
        }
    }

    func compress() {
        // Also refused while a switch is in flight: `switchVersions`'s promote is still rewriting
        // the shipped path an outstanding switch owns, and a fresh run here would hand out cache
        // reservations for paths that are transiently absent mid-swap (R9).
        guard let engine, !isRunning, switchesInFlight.isEmpty else { return }
        let chosen = preset
        let folder = outputFolder
        // Allocate every output name up front, serially, on this thread — BEFORE the concurrent
        // run starts — so two same-basename inputs from different folders can't both claim the same
        // target and fail the second job's atomic rename (a purely on-disk check races under
        // concurrency). Each job then looks up its pre-reserved, guaranteed-unique destination.
        var reserved = Set<String>()
        // Seed every row's existing result path, and both its parked cache slots, BEFORE
        // allocating anything. A recompress commit parks then promotes, so the shipped file is
        // transiently absent, and `promote`'s cache-slot step is best-effort — a `previous` (or
        // `runnerUp`) file can be transiently OR permanently absent while its row still owns that
        // path. Either way a queued same-basename job must be kept off it by the reservation,
        // never by the file happening to exist now (R11) — otherwise a second row's cache
        // allocation can land on a first row's still-live parked slot and overwrite its content.
        for job in queue.jobs {
            for card in versionStore.versions(for: job.id)?.cards ?? [] {
                reserved.insert(FileNaming.reservationKey(for: card.version.url))
            }
        }
        var outputs: [ToolJob.ID: URL] = [:]
        var alternates: [ToolJob.ID: URL] = [:]
        for job in queue.jobs {
            outputs[job.id] = FileNaming.output(for: job.url, suffix: "compressed",
                                                folder: folder, reserving: &reserved)
            // Runner-up name from the same serial allocator, into the cache root (C4/R15). Only a
            // job that RETAINS a second variant actually writes this file; the rest just hold the
            // reservation.
            alternates[job.id] = store.reserveURL(for: job.url, reserving: &reserved)
            // Only for the rows this batch will actually run: `ToolQueue.execute` picks up
            // `.queued` jobs only, so recording the current preset against a finished row from an
            // earlier batch would misattribute it — and a later R10 re-run would rewrite that row's
            // delivered file under a preset it was never compressed at. (The reservations above
            // stay unfiltered: a finished row still owns its output and runner-up paths, and this
            // batch must not hand either to a new same-basename job.)
            if isStillQueued(job) { pendingPresets[job.id] = chosen }
        }
        // `armedJobs` is read BEFORE `isRunning` goes true: arming is suppressed for the duration
        // of a run (R9), so the set must be captured while it still exists.
        let armed = armedJobs
        let plans: [RecompressPlan] = armed.map { job in
            let shipped = versionStore.versions(for: job.id)?.shipped
            // R11: the row's own result path, even if "Save to" changed since. A row that shipped
            // nothing (no-gain) has none, so it takes the name the loop above ALREADY allocated for
            // it — `jobs` is a 1:1 map of `queue.jobs`, so an armed row is always in that loop and
            // `outputs[job.id]` is always present. Allocating a second time from the same
            // `reserved` ledger would collide with the first pass's own entry and hand the row
            // `<name>-compressed-1.pdf`.
            let output = shipped?.url ?? outputs[job.id]
                ?? FileNaming.output(for: job.url, suffix: "compressed", folder: folder,
                                     reserving: &reserved)
            return RecompressPlan(
                id: job.id, url: job.url, target: chosen, output: output,
                temp: output.deletingLastPathComponent()
                    .appendingPathComponent(".toolbox-recompress-\(UUID().uuidString).pdf"),
                parked: versionStore.reservePreviousURL(for: job.url, reserving: &reserved),
                runnerUp: store.reserveURL(for: job.url, reserving: &reserved))
        }
        let queuedIDs = queue.jobs.filter(isStillQueued).map(\.id)
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
        isRunning = true
        Task {
            // Phase 1 — the queued rows, through the shared queue exactly as before.
            await queue.run { job, report in
                // A missing reservation means `add` let a file into the batch after the up-front
                // allocation pass — fail this one job loudly rather than silently allocating a
                // second, racing name from inside the concurrent run (see
                // `MissingOutputReservationError`).
                guard let output = outputs[job.id] else {
                    throw MissingOutputReservationError()
                }
                let alternate = alternates[job.id]
                // Captured here, per job invocation, so each concurrent job's report lands on
                // that job's own `JobResult` rather than a shared/racing variable.
                var capturedReport: MRCDocumentReport?
                let outcome = try await engine.compress(job.url, preset: chosen, to: output,
                                                        alternateOutput: alternate,
                                                        mrcReport: { capturedReport = $0 }) { report($0) }
                // `.noGain` deliberately writes nothing, so there is no output file to point at.
                if case .noGain = outcome.compress {
                    return JobResult(outcome, mrcReport: capturedReport)
                }
                // The alternate is attached whenever a second variant was RETAINED — keyed on the
                // descriptor, never on which variant won the gate (spec §5's R7 reversal).
                if outcome.runnerUp != nil {
                    return JobResult(outcome, outputURL: output, alternateURL: alternate,
                                     mrcReport: capturedReport)
                }
                return JobResult(outcome, outputURL: output, mrcReport: capturedReport)
            }
            // Phase 2 — the armed rows, through the engine directly. SERIALISED after phase 1, not
            // alongside it: running both mechanisms at once would put 2 × the batch width of gs
            // processes on the machine, and the spec bounds the total to one normal batch. One
            // button, one bar, one cancel — and the bound holds by construction (Risk 2).
            // `runRecompressPhase` opens with the `runCancelled` guard, which is what makes a
            // cancel landing during phase 1 stop the run here instead of starting phase 2.
            await runRecompressPhase(plans, engine: engine)
            // The batch is over: its in-flight reservations are settled (every committed runner-up
            // is now owned by `versionStore`), so nothing here is `cancel`'s to discard any more.
            runReservations = [:]
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
        do {
            let outcome = try await engine.compress(plan.url, preset: plan.target, to: plan.temp,
                                                    alternateOutput: plan.runnerUp,
                                                    mrcReport: { capturedReport = $0 },
                                                    progress: report)
            // The engine may return normally after its own final checkpoint (`CompressEngine`'s
            // last `Task.checkCancellation()` precedes the rename-and-return), so a cancel landing
            // in that window arrives here as a successful outcome — committing it would overwrite
            // the file the user already has, which is exactly what R9 forbids.
            try Task.checkCancellation()
            try await commit(outcome, plan: plan, report: capturedReport)
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
    /// discard loop walks `runReservations` — the batch's up-front runner-up allocation — and so
    /// never reaches the separate reservation a plan carries. R9's cancel semantics are unchanged
    /// too: the swap runs on a GCD queue bridged with a checked continuation, which does not inherit
    /// cancellation, so one already begun runs to completion rather than tearing at a `Task`
    /// cancellation — that guarantee does not extend to a crash or quit mid-swap, which can still
    /// strand the shipped file at `performSwap`'s dot-temp, the same accepted residual the engine's
    /// own `destTemp` carries.
    private func commit(_ outcome: RowOutcome, plan: RecompressPlan,
                        report: MRCDocumentReport?) async throws {
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
        case .compressed(_, let after):
            shippedBytes = after
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
            futileAttempts.insert(FutileAttempt(id: plan.id, preset: plan.target))
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
        } else {
            // Either the row shipped nothing (no version to park), or it shipped a version whose
            // file was deleted/moved outside the app — `promote`'s first step (`moveItem(at:
            // shipped, to: temp)`) would throw NSFileNoSuchFileError on that file, so there is
            // nothing to park either way. `plan.output` is the row's existing result path when one
            // exists (R11), so the fresh result simply lands there directly — the recompress
            // succeeded and there is no lie to tell (R12).
            // Inline on the main actor, deliberately unlike `promote`: `plan.temp` is allocated in
            // `plan.output`'s own directory, so this is a same-volume rename, not a copy — a
            // metadata-only operation, not the payload I/O `promote`'s off-actor hop exists for.
            try FileManager.default.moveItem(at: plan.temp, to: plan.output)
            versionStore.setShipped(FileVersion(url: plan.output, bytes: shippedBytes,
                                                preset: plan.target, variant: variant),
                                    for: plan.id)
        }
        versionStore.setSlot(.runnerUp, to: runnerUp, for: plan.id)
        if runnerUp == nil { store.discard(plan.runnerUp) }
        if let report { rerunReports[plan.id] = report }
        // R13: a result larger than the version they had still ships — they chose the quality —
        // with honest sizes. The engine guarantees it is smaller than the ORIGINAL; anything else
        // came back `.noGain` above.
    }

    // MARK: per-file estimate

    private func scheduleEstimate(for job: ToolJob) {
        estimationTasks[job.id]?.cancel()
        analysingIDs.insert(job.id)
        publishJobs()

        estimationTasks[job.id] = Task { [weak self] in
            guard let self else { return }
            let analysis = await self.estimator.analyse(job.url)
            guard !Task.isCancelled else { return }
            self.analyses[job.id] = analysis
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
        recompressErrors = recompressErrors.filter { liveIDs.contains($0.key) }
        rerunReports = rerunReports.filter { liveIDs.contains($0.key) }
        switchFailures = switchFailures.filter { liveIDs.contains($0.key) }
        futileAttempts = futileAttempts.filter { liveIDs.contains($0.id) }
        // `switchesInFlight` gates `compress()`/`canCompress`/`clearFinished()` (a416a19/0edc769):
        // an id orphaned here — e.g. a row cleared mid-switch — would leave those refused for the
        // rest of the session even after the re-run's own tail has nothing left to clear it with.
        switchesInFlight = switchesInFlight.filter { liveIDs.contains($0) }
        rerunProgress = rerunProgress.filter { liveIDs.contains($0.key) }
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
            display.estimate = analyses[job.id]?.estimates[preset]
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
        guard case .done(let outcome) = job.state else { return .none }
        switch outcome.compress {
        // A `.failed` row never arms (its recourse is re-adding the file), and neither does a row
        // whose compress leg never ran or was skipped — there is nothing to recompress from.
        case nil, .skipped: return .none
        case .compressed, .noGain: break
        }
        // A row whose delivered file could not be backed any more has nothing to recompress from.
        guard let row = versions(for: job) else { return .none }
        let target = preset
        // Ahead of the row-preset check on purpose: a row that came back no-gain at its own preset
        // must show the futile caption rather than read as a plain, unremarkable finished row.
        if futileAttempts.contains(FutileAttempt(id: job.id, preset: target)) { return .futile(target) }
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
    /// The estimator models the gs path only, so its figure is calibrated by what the engine
    /// actually did — but ONLY when the same path is expected to run again. `wantsMRC` is
    /// `classification == .scanColour && preset != .maximumQuality`, so an MRC-shipped row crossing
    /// to Maximum quality, or a gs-shipped row moving to an MRC-eligible preset, both change path
    /// and take the raw estimate: a ratio learned on one path does not transfer to the other.
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
            let targetWantsMRC = classification == .scanColour && target != .maximumQuality
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
            guard let predicted = recompressPrediction(for: job, at: preset),
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
        handedOffToRerun = rerunForSwitch(job, wantHeavy: parked.variant == .mrc)
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
    private func rerunForSwitch(_ job: ToolJob, wantHeavy: Bool) -> Bool {
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
            let id = job.id
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.switchesInFlight.contains(id) else { return }
                    self.rerunProgress[id] = fraction
                    self.publishJobs()
                }
            }
            // The engine's delivery contract never overwrites an existing destination (it
            // `moveItem`s the winner into place), and `shipped` still holds the pre-rerun file at
            // this point — targeting it directly throws `NSFileWriteFileExistsError`, which the
            // outer catch below would silently swallow into a no-op switch. So the primary output
            // goes to a fresh, guaranteed-absent temp file instead, landed into `shipped`
            // afterwards.
            let freshShipped = shipped.deletingLastPathComponent()
                .appendingPathComponent(".toolbox-rerun-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: freshShipped) }
            // The runner-up was confirmed absent before this tail was entered, but that check and
            // this re-run are not one atomic step — anything (a sync client, the user) may have put
            // a file back at that path in between. The engine writes the runner-up with a
            // best-effort `copyItem`, which throws (and is swallowed) onto an occupied destination,
            // so a surviving file would stay STALE beside a freshly regenerated winner and the next
            // switch would hand the user one version under the other's label. Clear the slot so the
            // pair matches.
            try? FileManager.default.removeItem(at: runnerUp)
            var capturedReport: MRCDocumentReport?
            // Whether the switch the user asked for actually landed. Set true only on the paths
            // that reach it, so a failed leg keeps whatever failure note it just recorded rather
            // than have it wiped by an unconditional clear (32380c4's rule, applied here too).
            var switched = false
            do {
                let outcome = try await engine.compress(job.url, preset: chosen, to: freshShipped,
                                                         alternateOutput: runnerUp,
                                                         mrcReport: { capturedReport = $0 },
                                                         progress: report)
                // The switch's post-regeneration step assumes the re-run reproduces the heavy
                // PAIR — an MRC winner with a runner-up parked beside it — with both files
                // written; that's an assumption about engine determinism, not a guarantee the type
                // gives us. Guard on the actual outcome: anything else (e.g. `.noGain`, or a
                // regeneration that retained nothing) means there is no runner-up to switch to, so
                // leave the row exactly as the engine left it. This is the one site that needs
                // BOTH facts — elsewhere the descriptor alone decides (spec §5's R7 reversal).
                if outcome.shippedVariant == .mrc, outcome.runnerUp != nil {
                    do {
                        // Land the regenerated heavy version atomically into the real shipped slot
                        // — the winner was never routed through `shipped` directly (see above).
                        _ = try FileManager.default.replaceItemAt(shipped, withItemAt: freshShipped)
                        // Regenerated canonical state: heavy shipped, runner-up parked. If the row
                        // was showing the parked version before the re-run, swap the descriptions
                        // back — the re-run reproduces the row's own pair, it never redefines it,
                        // so no new byte counts are invented here.
                        if versionStore.versions(for: id)?.shipped?.variant != .mrc {
                            versionStore.swapShipped(with: .runnerUp, for: id)
                        }
                        rerunReports[id] = capturedReport
                        if wantHeavy {
                            switched = true
                        } else {
                            do {
                                try await store.switchVersions(shipped: shipped, runnerUp: runnerUp)
                                versionStore.swapShipped(with: .runnerUp, for: id)
                                switched = true
                            } catch let stranded as RunnerUpStore.SwitchError {
                                // The regenerated winner is parked under a hidden name that
                                // nothing else looks for — the row must name it, not report a
                                // switch that silently cost the user their file.
                                reportSwitchFailure(id, stranded.localizedDescription)
                            } catch {
                                // The switch did not happen and `shipped` is unchanged (store
                                // contract: any other throw restores it) — heavy is still shipped,
                                // so leave the store's record canonical rather than describe a
                                // switch that never took effect, and say so — an explicit button
                                // press never fails silently (R12).
                                recompressErrors[id] = "Switch failed — kept your "
                                                     + "\(chosen.title) version. Try again."
                            }
                        }
                    } catch {
                        // Landing the regenerated heavy version failed; `shipped` is untouched
                        // (`replaceItemAt`'s atomic guarantee) so the store's record stays exactly
                        // as it was. The engine already wrote the runner-up straight to its slot —
                        // orphaned now that there is nothing to switch to, so discard it.
                        try? FileManager.default.removeItem(at: runnerUp)
                    }
                }
            } catch {
                // Re-run failed; leave the row's prior state untouched (its shipped file survives).
            }
            // A retry that succeeds must not leave the previous attempt's failure note beside the
            // row (32380c4); a leg that failed above has just set its own message and must keep it.
            if switched { recompressErrors[id] = nil }
            switchesInFlight.remove(id)
            rerunProgress[id] = nil
            publishJobs()
        }
        return true
    }
}

/// The compression capability `CompressViewModel` depends on — a seam so tests can stub the engine
/// without invoking the real MRC pipeline. `CompressEngine` is the sole production implementation.
/// `Sendable` because the job body that calls it is handed to `ToolQueue`'s task group.
protocol Compressing: Sendable {
    func compress(_ input: URL,
                  preset: CompressPreset,
                  to output: URL,
                  alternateOutput: URL?,
                  mrcReport: ((MRCDocumentReport) -> Void)?,
                  progress: @escaping (Double) -> Void) async throws -> RowOutcome
}

extension CompressEngine: Compressing {}
