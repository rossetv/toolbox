// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// What a job produced: its outcome, and where the output landed (nil when nothing was written —
/// a no-gain compress keeps the original, so there is no new file to reveal or open).
struct JobResult {
    let outcome: RowOutcome
    let outputURL: URL?
    /// The retained runner-up output (Rung-3's plain-gs alternative), if the body produced one.
    let alternateURL: URL?
    /// The MRC per-page report (spec §6's debugging record), if the body produced one.
    let mrcReport: MRCDocumentReport?

    init(_ outcome: RowOutcome, outputURL: URL? = nil, alternateURL: URL? = nil,
         mrcReport: MRCDocumentReport? = nil) {
        self.outcome = outcome
        self.outputURL = outputURL
        self.alternateURL = alternateURL
        self.mrcReport = mrcReport
    }
}

/// The batch runner shared by both tools. It owns per-job state and runs jobs with bounded
/// concurrency; the tool supplies the per-job `body`.
///
/// Contract:
///  - the body is `(ThisJob, report) async throws -> JobResult`; it must **suspend** on its
///    blocking work (never block a cooperative-pool thread) so the concurrency cap is real;
///  - each `report(fraction)` sets that job `.running(fraction)`; the body's return sets
///    `.done(outcome)`; a **throw sets that one job `.failed` and the batch continues**;
///  - `cancel()` stops launching queued jobs and cancels running ones — a cancelled job
///    returns to `.queued` and (by the engine's atomic-write contract) leaves no partial output;
///  - **one batch at a time**: `run` while a batch is in flight is a no-op, so the live batch can
///    never be orphaned from `cancel()`. The invariant lives here, in the type that owns the task.
@MainActor
final class ToolQueue: ObservableObject {
    @Published private(set) var jobs: [ToolJob] = []

    private var runTask: Task<Void, Never>?

    /// Accepted at any time, a live batch included (spec §6.5). `execute`'s launch loop re-polls
    /// the queue as each job finishes rather than working from a snapshot taken at `run`'s start,
    /// so a row added mid-batch is picked up by the batch it landed in. The one window this cannot
    /// reach is an add that lands after the last running job has already completed: the batch is
    /// over by then, and the row simply stays `.queued` as pending work for the next Start.
    ///
    /// The caller still owns delivery names — `QueueViewModel` reserves them at add time, which is
    /// what made this admission safe. A caller that allocates names at run start must keep its own
    /// guard.
    func add(_ urls: [URL]) {
        jobs.append(contentsOf: urls.map(ToolJob.init(url:)))
    }

    /// Point a row at a different file and return it to the start of its life — the "Find it…"
    /// rebind (spec §7's Problems screen). Everything the previous file produced is dropped: the
    /// row is describing a different document now.
    ///
    /// Refused on a running row: pulling the input out from under a job in flight would orphan the
    /// work exactly as `remove(_:)`'s guard prevents. The invariant lives here, in the type that
    /// owns the state (§6.3).
    func rebind(_ id: ToolJob.ID, to url: URL) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if case .running = jobs[index].state { return }
        jobs[index].url = url
        jobs[index].state = .queued
        jobs[index].resultURL = nil
        jobs[index].alternateURL = nil
        jobs[index].estimate = nil
        jobs[index].mrcReport = nil
    }

    /// Remove one job. Only a job that has not started is removable — pulling a running job out
    /// from under its engine would orphan the work in flight.
    func remove(_ id: ToolJob.ID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if case .queued = jobs[i].state { jobs.remove(at: i) }
    }

    func removeCompleted() {
        jobs.removeAll { job in
            switch job.state {
            case .done, .failed: return true
            default: return false
            }
        }
    }

    /// Run every queued job through `body`, at most `maxConcurrent` at once — including rows
    /// added after the batch started (see `add`). Returns when all launched jobs have reached a
    /// terminal state (or been cancelled).
    ///
    /// `skipping` names rows the caller has excluded from this run (the Problems screen's Skip).
    /// They are never launched, so they never flash `.running` and are left exactly as they are.
    ///
    /// A call made while a batch is already running returns immediately without touching the
    /// queue: overwriting `runTask` would leave the live batch running with nothing able to
    /// cancel it. (Both view models also gate on `isRunning`, but the invariant belongs here.)
    func run(_ body: @escaping (ToolJob, _ report: @escaping @Sendable (Double) -> Void) async throws -> JobResult,
             maxConcurrent: Int = SystemInfo.performanceCoreCount,
             skipping: Set<ToolJob.ID> = []) async {
        guard runTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(body: body, maxConcurrent: max(1, maxConcurrent), skipping: skipping)
        }
        runTask = task
        // Cleared on the way out so a later `cancel()` can't cancel a finished task, and the next
        // batch is admitted.
        defer { runTask = nil }
        await task.value
    }

    func cancel() {
        runTask?.cancel()
    }

    // MARK: private

    private func execute(body: @escaping (ToolJob, @escaping @Sendable (Double) -> Void) async throws -> JobResult,
                         maxConcurrent: Int, skipping: Set<ToolJob.ID>) async {
        // Re-polled rather than snapshotted, which is what lets a row added mid-batch join it
        // (spec §6.5). `launched` is the memory a snapshot used to provide: a job cancelled
        // mid-flight goes back to `.queued` by design, and without this it would be picked up
        // again by the very batch that was cancelling it.
        var launched: Set<ToolJob.ID> = []
        var free = maxConcurrent

        await withTaskGroup(of: Void.self) { group in
            // Sliding window: keep at most `maxConcurrent` in flight; launch the next as each
            // finishes (NOT add-all, which would ignore the cap).
            while true {
                while free > 0, !Task.isCancelled,
                      let id = self.nextQueuedID(excluding: launched, skipping: skipping) {
                    launched.insert(id)
                    free -= 1
                    group.addTask { [weak self] in
                        await self?.process(id: id, body: body)
                    }
                }
                guard await group.next() != nil else { break }
                free += 1
            }
        }
    }

    /// The next job this batch may launch: still `.queued`, not already launched by this batch,
    /// and not excluded by the caller. Re-read from `jobs` on every call — that read is the whole
    /// mechanism behind mid-run admission.
    private func nextQueuedID(excluding launched: Set<ToolJob.ID>,
                              skipping: Set<ToolJob.ID>) -> ToolJob.ID? {
        jobs.first { job in
            guard case .queued = job.state else { return false }
            return !launched.contains(job.id) && !skipping.contains(job.id)
        }?.id
    }

    private func process(id: UUID,
                         body: @escaping (ToolJob, @escaping @Sendable (Double) -> Void) async throws -> JobResult) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if Task.isCancelled { return }   // cancelled before starting → stays .queued

        setState(id, .running(0))
        // Formed here on @MainActor but invoked by the engines from `DispatchQueue.global` — must
        // be `@Sendable` to cross that boundary legitimately. Delivered via the main QUEUE, not an
        // unstructured `Task { @MainActor }` per tick: tasks carry no ordering guarantee, so two
        // ticks could land swapped and walk the progress bar backwards; the main queue is FIFO.
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.setState(id, .running(fraction)) }
            }
        }

        do {
            let result = try await body(job, report)
            if let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index].resultURL = result.outputURL
                jobs[index].alternateURL = result.alternateURL
                jobs[index].mrcReport = result.mrcReport
            }
            setState(id, .done(result.outcome))
        } catch is CancellationError {
            setState(id, .queued)        // interrupted; engine's atomic write left no partial output
        } catch {
            setState(id, .failed(error.localizedDescription))
        }
    }

    private func setState(_ id: UUID, _ state: JobState) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        // A progress tick hops through the main queue (see `report` in `process`) and can still
        // land after the job already reached `.done`/`.failed` — e.g. `OCREngine.ocr` calls
        // `progress(1.0)` immediately before returning, immediately before `process` sets `.done`.
        // Applying it anyway would resurrect a finished job back to `.running`, and since
        // `removeCompleted()` only matches `.done`/`.failed`, that job would then be stranded
        // forever. Only apply `.running` while the job is still `.queued` or already `.running`.
        if case .running = state {
            switch jobs[index].state {
            case .queued, .running: break
            default: return
            }
        }
        jobs[index].state = state
    }
}
