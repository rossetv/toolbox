// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
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

    let queue = ToolQueue()
    private let engine: CompressEngine?
    private let estimator: CompressEstimator
    private var cancellable: AnyCancellable?

    /// The queue's own jobs, unmodified — `jobs` above is derived from this plus the local
    /// estimate/analysing state below.
    private var rawJobs: [ToolJob] = []
    /// Predictions for every preset, per job — computed once, so changing preset is a lookup.
    private var estimates: [UUID: [CompressPreset: SizeEstimate]] = [:]
    private var analysingIDs: Set<UUID> = []
    private var estimationTasks: [UUID: Task<Void, Never>] = [:]

    init(estimator: CompressEstimator = CompressEstimator()) {
        self.estimator = estimator
        if let runner = try? GhostscriptRunner() {
            engine = CompressEngine(runner: runner)
        } else {
            engine = nil
            loadError = "Ghostscript is missing from the app bundle — the app cannot compress."
        }
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

    func remove(_ job: ToolJob) { queue.remove(job.id) }

    func clearFinished() {
        queue.removeCompleted()
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
        var reserved = Set<URL>()
        var outputs: [ToolJob.ID: URL] = [:]
        for job in queue.jobs {
            outputs[job.id] = FileNaming.output(for: job.url, suffix: "compressed",
                                                folder: folder, reserving: &reserved)
        }
        isRunning = true
        Task {
            await queue.run { job, report in
                let output = outputs[job.id]
                    ?? FileNaming.output(for: job.url, suffix: "compressed", folder: folder)
                let outcome = try await engine.compress(job.url, preset: chosen, to: output) { report($0) }
                // `.noGain` deliberately writes nothing, so there is no output file to point at.
                if case .noGain = outcome { return JobResult(outcome) }
                return JobResult(outcome, outputURL: output)
            }
            isRunning = false
        }
    }

    func cancel() {
        queue.cancel()
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
            if analysingIDs.contains(job.id), isStillQueued(job) {
                display.state = .analysing
            }
            return display
        }
    }
}
