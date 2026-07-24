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
        didSet { if preset != oldValue { reestimatePendingJobs() } }
    }
    @Published var outputFolder: URL?
    @Published private(set) var jobs: [ToolJob] = []
    /// Page count per job, resolved off the main actor as files are added.
    @Published private(set) var pageCounts: [ToolJob.ID: Int] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var loadError: String?
    /// Rows currently in the R10 re-run path — the runner-up vanished, so the switch is honestly
    /// re-computing the job before applying the requested version (the view shows progress).
    @Published private(set) var isSwitchRerunning: Set<ToolJob.ID> = []

    let queue = ToolQueue()
    private let engine: (any Compressing)?
    private let estimator: CompressEstimator
    private let store: RunnerUpStore
    private var cancellable: AnyCancellable?

    /// Rows whose user-visible file currently holds the *normal* (plain-gs) version — i.e. the
    /// switch has been applied. Absent ⇒ the row still ships the heavy (MRC) version (R10). The
    /// files are swapped in place, so this membership is the only record of which way a row points.
    private var switched: Set<ToolJob.ID> = []
    /// Progress fraction for a job in the R10 re-run path, overlaid onto its published state.
    private var rerunProgress: [ToolJob.ID: Double] = [:]
    /// MRC reports produced by an R10 re-run (spec §6's debugging record), overlaid onto the
    /// published job since the re-run bypasses `ToolQueue.run` and never touches `queue.jobs`.
    private var rerunReports: [ToolJob.ID: MRCDocumentReport] = [:]
    /// The preset each job was compressed under, so an R10 re-run reproduces the *same* output
    /// rather than silently rewriting the shipped file under a preset the user changed since.
    private var jobPresets: [ToolJob.ID: CompressPreset] = [:]
    /// Runner-up files reserved for the in-flight batch, so `cancel()` can discard the ones whose
    /// jobs never completed as heavy. Cleared when the batch ends; done-heavy runner-ups persist on
    /// the job's `alternateURL` and are discarded via `remove`/`clearFinished` instead.
    private var batchAlternates: [ToolJob.ID: URL] = [:]

    /// The queue's own jobs, unmodified — `jobs` above is derived from this plus the local
    /// estimate/analysing state below.
    private var rawJobs: [ToolJob] = []
    /// Predictions for every preset, per job — computed once, so changing preset is a lookup.
    private var estimates: [UUID: [CompressPreset: SizeEstimate]] = [:]
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
            self.pruneStaleEstimateState()
            self.publishJobs()
        }
    }

    var hasQueuedWork: Bool {
        jobs.contains { if case .queued = $0.state { return true } else { return false } }
    }

    var canCompress: Bool { engine != nil && !isRunning && hasQueuedWork }

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
        discardRunnerUp(for: job)
        queue.remove(job.id)
    }

    func clearFinished() {
        for job in jobs where isFinished(job) { discardRunnerUp(for: job) }
        queue.removeCompleted()
    }

    /// Discard a job's cached runner-up and forget its switch/preset bookkeeping (R15).
    private func discardRunnerUp(for job: ToolJob) {
        if let alternate = job.alternateURL { store.discard(alternate) }
        switched.remove(job.id)
        jobPresets[job.id] = nil
        batchAlternates[job.id] = nil
    }

    private func isFinished(_ job: ToolJob) -> Bool {
        switch job.state {
        case .done, .failed: return true
        default: return false
        }
    }

    var allFinished: Bool { !jobs.isEmpty && !isRunning && jobs.allSatisfy { if case .done = $0.state { return true }; if case .failed = $0.state { return true }; return false } }

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
        guard let engine, !isRunning else { return }
        let chosen = preset
        let folder = outputFolder
        // Allocate every output name up front, serially, on this thread — BEFORE the concurrent
        // run starts — so two same-basename inputs from different folders can't both claim the same
        // target and fail the second job's atomic rename (a purely on-disk check races under
        // concurrency). Each job then looks up its pre-reserved, guaranteed-unique destination.
        var reserved = Set<String>()
        var outputs: [ToolJob.ID: URL] = [:]
        var alternates: [ToolJob.ID: URL] = [:]
        for job in queue.jobs {
            outputs[job.id] = FileNaming.output(for: job.url, suffix: "compressed",
                                                folder: folder, reserving: &reserved)
            // Runner-up name from the same serial allocator, into the cache root (C4/R15). Only a
            // `.compressedHeavy` job actually writes this file; the rest just hold the reservation.
            alternates[job.id] = store.reserveURL(for: job.url, reserving: &reserved)
            jobPresets[job.id] = chosen
        }
        batchAlternates = alternates
        isRunning = true
        Task {
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
                switch outcome {
                // `.noGain` deliberately writes nothing, so there is no output file to point at.
                case .noGain:
                    return JobResult(outcome, mrcReport: capturedReport)
                // The heavy result retains the plain-gs version as the runner-up for the switch.
                case .compressedHeavy:
                    return JobResult(outcome, outputURL: output, alternateURL: alternate,
                                     mrcReport: capturedReport)
                default:
                    return JobResult(outcome, outputURL: output, mrcReport: capturedReport)
                }
            }
            // The batch is over: its in-flight reservations are settled (done-heavy runner-ups now
            // live on the job's `alternateURL`), so nothing here is `cancel`'s to discard anymore.
            batchAlternates = [:]
            isRunning = false
        }
    }

    func cancel() {
        queue.cancel()
        // Discard the in-flight batch's runner-ups, except any job that already completed as heavy
        // (its file is retained for the switch). A cancelled job returns to `.queued` and, by the
        // engine's atomic-write contract, leaves no partial output — so this only reclaims files a
        // completed-but-superseded job wrote before the cancel landed (R15).
        for (id, url) in batchAlternates where !isDoneHeavy(id) {
            store.discard(url)
        }
        batchAlternates = [:]
    }

    private func isDoneHeavy(_ id: ToolJob.ID) -> Bool {
        guard let job = rawJobs.first(where: { $0.id == id }) else { return false }
        if case .done(.compressedHeavy) = job.state { return true }
        return false
    }

    // MARK: per-file estimate

    private func scheduleEstimate(for job: ToolJob) {
        estimationTasks[job.id]?.cancel()
        analysingIDs.insert(job.id)
        publishJobs()

        estimationTasks[job.id] = Task { [weak self] in
            guard let self else { return }
            let all = await self.estimator.estimateAll(job.url)
            guard !Task.isCancelled else { return }
            self.estimates[job.id] = all
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
        estimates = estimates.filter { liveIDs.contains($0.key) }
        analysingIDs = analysingIDs.filter { liveIDs.contains($0) }
        switched = switched.filter { liveIDs.contains($0) }
        jobPresets = jobPresets.filter { liveIDs.contains($0.key) }
        rerunReports = rerunReports.filter { liveIDs.contains($0.key) }
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
            display.estimate = estimates[job.id]?[preset]
            if let rerunReport = rerunReports[job.id] { display.mrcReport = rerunReport }
            if isSwitchRerunning.contains(job.id) {
                // R10 re-run overlay: the queue still reports the job `.done`, but the switch is
                // re-computing it, so the row shows progress until the re-run lands.
                display.state = .running(rerunProgress[job.id] ?? 0)
            } else if analysingIDs.contains(job.id), isStillQueued(job) {
                display.state = .analysing
            }
            return display
        }
    }

    // MARK: heavy-version switch (R8–R11)

    /// Row-facing switch state. nil = row has no alternate (today's behaviour, R7).
    struct HeavyVersions: Equatable {
        let shippedIsHeavy: Bool      // false after a switch to normal
        let heavyBytes: Int
        let normalBytes: Int
        let shippedURL: URL           // the user-visible output file
        let runnerUpURL: URL          // the cache-held loser

        /// The byte count of whichever version is currently shipped — what the row's badge must
        /// show, since `heavyBytes`/`normalBytes` are fixed per version and only `shippedIsHeavy`
        /// tracks which one is actually on disk.
        var displayedBytes: Int { shippedIsHeavy ? heavyBytes : normalBytes }
    }

    /// The two versions available for `job`, or nil when the job produced no runner-up. The byte
    /// counts are intrinsic to each version (they never move); only `shippedIsHeavy` flips on a
    /// switch, because the switch swaps the files' *content* in place, not their paths.
    func heavyVersions(for job: ToolJob) -> HeavyVersions? {
        guard case .done(.compressedHeavy(_, let heavyBytes, let normalBytes)) = job.state,
              let shippedURL = job.resultURL,
              let runnerUpURL = job.alternateURL else { return nil }
        return HeavyVersions(shippedIsHeavy: !switched.contains(job.id),
                             heavyBytes: heavyBytes,
                             normalBytes: normalBytes,
                             shippedURL: shippedURL,
                             runnerUpURL: runnerUpURL)
    }

    /// The before/after byte pair `job` contributes to the batch's savings totals, or nil when
    /// the job produced no savings outcome (queued/running/failed/noGain/OCR). For a heavy job,
    /// `after` is the SHIPPED version's bytes (`heavyVersions(for:).displayedBytes`), so a switch
    /// keeps the batch totals in sync with the row's own badge.
    func savedBytes(for job: ToolJob) -> (before: Int, after: Int)? {
        guard case .done(let outcome) = job.state else { return nil }
        switch outcome {
        case .compressed(let before, let after):
            return (before, after)
        case .compressedHeavy(let before, let after, _):
            return (before, heavyVersions(for: job)?.displayedBytes ?? after)
        case .noGain, .ocrAdded, .alreadySearchable:
            return nil
        }
    }

    /// The popover's switch button. Instant when the runner-up still exists; if it has vanished,
    /// honestly re-runs the job and applies the requested switch on completion (R10).
    func switchVersion(for job: ToolJob) {
        guard let versions = heavyVersions(for: job) else { return }
        let wantHeavy = !versions.shippedIsHeavy   // the switch flips which version ships
        let shipped = versions.shippedURL
        let runnerUp = versions.runnerUpURL

        if FileManager.default.fileExists(atPath: runnerUp.path) {
            do {
                try store.switchVersions(shipped: shipped, runnerUp: runnerUp)
                if switched.contains(job.id) { switched.remove(job.id) } else { switched.insert(job.id) }
                publishJobs()   // no state moved, but the row's badge/capsule read from `switched`
                return
            } catch {
                // The switch did not happen (the runner-up raced away) — fall through to the re-run.
            }
        }
        rerunForSwitch(job, wantHeavy: wantHeavy)
    }

    /// R10 tail: the runner-up is gone, so re-run this one job directly through the engine (not the
    /// batch queue) to regenerate both versions, then apply the switch the user asked for.
    private func rerunForSwitch(_ job: ToolJob, wantHeavy: Bool) {
        guard let engine,
              let shipped = job.resultURL,
              let runnerUp = job.alternateURL else { return }
        let chosen = jobPresets[job.id] ?? preset
        isSwitchRerunning.insert(job.id)
        rerunProgress[job.id] = 0
        publishJobs()

        Task {
            let id = job.id
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.isSwitchRerunning.contains(id) else { return }
                    self.rerunProgress[id] = fraction
                    self.publishJobs()
                }
            }
            // The engine's delivery contract never overwrites an existing destination (it
            // `moveItem`s the winner into place), and `shipped` still holds the pre-rerun file at
            // this point — targeting it directly throws `NSFileWriteFileExistsError`, which the
            // outer catch below would silently swallow into a no-op switch. So the primary output
            // goes to a fresh, guaranteed-absent temp file instead, landed into `shipped`
            // afterwards. `runnerUp` is safe to pass straight through as `alternateOutput`: this
            // path only ever runs when it is missing.
            let freshShipped = shipped.deletingLastPathComponent()
                .appendingPathComponent(".toolbox-rerun-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: freshShipped) }
            var capturedReport: MRCDocumentReport?
            do {
                let outcome = try await engine.compress(job.url, preset: chosen, to: freshShipped,
                                                         alternateOutput: runnerUp,
                                                         mrcReport: { capturedReport = $0 },
                                                         progress: report)
                // The switch's post-regeneration step assumes the re-run reproduces
                // `.compressedHeavy` with both the shipped and runner-up files written — that's an
                // assumption about engine determinism, not a guarantee the type gives us. Guard on
                // the actual outcome: anything else (e.g. `.noGain`) means there is no runner-up to
                // switch to, so leave the row exactly as the engine left it.
                if case .compressedHeavy = outcome {
                    do {
                        // Land the regenerated heavy version atomically into the real shipped slot
                        // — the winner was never routed through `shipped` directly (see above).
                        _ = try FileManager.default.replaceItemAt(shipped, withItemAt: freshShipped)
                        // Regenerated canonical state: heavy shipped, runner-up present.
                        switched.remove(id)
                        rerunReports[id] = capturedReport
                        if !wantHeavy {
                            do {
                                try store.switchVersions(shipped: shipped, runnerUp: runnerUp)
                                switched.insert(id)
                            } catch {
                                // The switch did not happen (store contract: a throw leaves
                                // `shipped` unchanged) — heavy is still shipped, so leave
                                // `switched` canonical rather than record a switch that never took
                                // effect.
                            }
                        }
                    } catch {
                        // Landing the regenerated heavy version failed; `shipped` is untouched
                        // (`replaceItemAt`'s atomic guarantee) so `switched` stays exactly as it
                        // was. The engine already wrote the runner-up straight to its real slot —
                        // orphaned now that there is nothing to switch to, so discard it.
                        try? FileManager.default.removeItem(at: runnerUp)
                    }
                }
            } catch {
                // Re-run failed; leave the row's prior state untouched (its shipped file survives).
            }
            isSwitchRerunning.remove(id)
            rerunProgress[id] = nil
            publishJobs()
        }
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
                  progress: @escaping (Double) -> Void) async throws -> JobOutcome
}

extension CompressEngine: Compressing {}
