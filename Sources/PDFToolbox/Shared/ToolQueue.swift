// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// The batch runner shared by both tools. It owns per-job state and runs jobs with bounded
/// concurrency; the tool supplies the per-job `body`.
///
/// Contract:
///  - the body is `(ThisJob, report) async throws -> JobOutcome`; it must **suspend** on its
///    blocking work (never block a cooperative-pool thread) so the concurrency cap is real;
///  - each `report(fraction)` sets that job `.running(fraction)`; the body's return sets
///    `.done(outcome)`; a **throw sets that one job `.failed` and the batch continues**;
///  - `cancel()` stops launching queued jobs and cancels running ones — a cancelled job
///    returns to `.queued` and (by the engine's atomic-write contract) leaves no partial output.
@MainActor
final class ToolQueue: ObservableObject {
    @Published private(set) var jobs: [ToolJob] = []

    private var runTask: Task<Void, Never>?

    func add(_ urls: [URL]) {
        jobs.append(contentsOf: urls.map(ToolJob.init(url:)))
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
    func run(_ body: @escaping (ToolJob, _ report: @escaping (Double) -> Void) async throws -> JobOutcome,
             maxConcurrent: Int = SystemInfo.performanceCoreCount) async {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(body: body, maxConcurrent: max(1, maxConcurrent))
        }
        runTask = task
        await task.value
    }

    func cancel() {
        runTask?.cancel()
    }

    // MARK: private

    private func execute(body: @escaping (ToolJob, @escaping (Double) -> Void) async throws -> JobOutcome,
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
                         body: @escaping (ToolJob, @escaping (Double) -> Void) async throws -> JobOutcome) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if Task.isCancelled { return }   // cancelled before starting → stays .queued

        setState(id, .running(0))
        let report: (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.setState(id, .running(fraction)) }
        }

        do {
            let outcome = try await body(job, report)
            setState(id, .done(outcome))
        } catch is CancellationError {
            setState(id, .queued)        // interrupted; engine's atomic write left no partial output
        } catch {
            setState(id, .failed(error.localizedDescription))
        }
    }

    private func setState(_ id: UUID, _ state: JobState) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }
}
