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
    let outcome: JobOutcome
    let outputURL: URL?

    init(_ outcome: JobOutcome, outputURL: URL? = nil) {
        self.outcome = outcome
        self.outputURL = outputURL
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

    func add(_ urls: [URL]) {
        jobs.append(contentsOf: urls.map(ToolJob.init(url:)))
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

    /// Run every currently-queued job through `body`, at most `maxConcurrent` at once.
    /// Returns when all launched jobs have reached a terminal state (or been cancelled).
    ///
    /// A call made while a batch is already running returns immediately without touching the
    /// queue: overwriting `runTask` would leave the live batch running with nothing able to
    /// cancel it. (Both view models also gate on `isRunning`, but the invariant belongs here.)
    func run(_ body: @escaping (ToolJob, _ report: @escaping @Sendable (Double) -> Void) async throws -> JobResult,
             maxConcurrent: Int = SystemInfo.performanceCoreCount) async {
        guard runTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(body: body, maxConcurrent: max(1, maxConcurrent))
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
                         maxConcurrent: Int) async {
        let queuedIDs: [UUID] = jobs.compactMap { job in
            if case .queued = job.state { return job.id } else { return nil }
        }
        var iterator = queuedIDs.makeIterator()

        await withTaskGroup(of: Void.self) { group in
            // Sliding window: keep at most `maxConcurrent` in flight; launch the next as each
            // finishes (NOT add-all, which would ignore the cap).
            func launchNext() {
                guard !Task.isCancelled, let id = iterator.next() else { return }
                group.addTask { [weak self] in
                    await self?.process(id: id, body: body)
                }
            }
            for _ in 0..<maxConcurrent { launchNext() }
            while await group.next() != nil {
                launchNext()
            }
        }
    }

    private func process(id: UUID,
                         body: @escaping (ToolJob, @escaping @Sendable (Double) -> Void) async throws -> JobResult) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if Task.isCancelled { return }   // cancelled before starting → stays .queued

        setState(id, .running(0))
        // Formed here on @MainActor but invoked by the engines from `DispatchQueue.global` — must
        // be `@Sendable` to cross that boundary legitimately.
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.setState(id, .running(fraction)) }
        }

        do {
            let result = try await body(job, report)
            if let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index].resultURL = result.outputURL
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
        // A progress tick is a separate, untracked `Task` (see `report` in `process`) and can land
        // after the job already reached `.done`/`.failed` — e.g. `OCREngine.ocr` calls
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
