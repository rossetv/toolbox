// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Combine
import Foundation

/// Drives the OCR tool: owns the shared `ToolQueue`, the OCR options and the `OCREngine`, and
/// mirrors the queue's jobs so the view re-renders on state changes (the same shape as
/// `CompressViewModel`).
@MainActor
final class OCRViewModel: ObservableObject {
    @Published var options = OCROptions()
    @Published private(set) var jobs: [ToolJob] = []
    @Published private(set) var isRunning = false

    let queue = ToolQueue()
    private let engine = OCREngine()
    private var cancellable: AnyCancellable?

    init() {
        // Subscribe synchronously: both ToolQueue and this view model are @MainActor, so a
        // `.receive(on: RunLoop.main)` hop is not only unnecessary but hazardous — Combine replays
        // the current value at subscription and the delayed hop can deliver that stale snapshot
        // after a same-tick mutation, and it adds a one-runloop-tick lag. (Matches CompressViewModel.)
        cancellable = queue.$jobs.sink { [weak self] in self?.jobs = $0 }
    }

    var hasQueuedWork: Bool {
        jobs.contains { if case .queued = $0.state { return true } else { return false } }
    }

    var canRun: Bool { !isRunning && hasQueuedWork }

    /// Only jobs the next run will actually process — counting finished rows too made the
    /// button promise "OCR 37 PDFs" when 8 were queued.
    var pageCandidateCount: Int {
        jobs.filter { if case .queued = $0.state { return true } else { return false } }.count
    }

    func add(_ urls: [URL]) {
        // Gated on `isRunning`: `run()` snapshots `queue.jobs` and reserves an output name for each
        // up front, but several MainActor hops separate that snapshot from the queue actually
        // launching jobs. A file added in that window would be `.queued` and run by the live batch
        // with no reserved name — the very race `outputs`/`reserved` exist to prevent.
        guard !isRunning else { return }
        // `isFileURL` is required, not decorative: a drag can deliver a remote URL (http, ftp),
        // which would otherwise be handed to the engine as if it were a local path.
        queue.add(urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" })
    }

    /// Drop a queued file from the batch. Without it the only ways to undo a mistaken drop were
    /// to run the file or quit the app (Compress has had `remove` since the start).
    func remove(_ job: ToolJob) {
        queue.remove(job.id)
    }

    func clearFinished() {
        queue.removeCompleted()
    }

    func run() {
        guard !isRunning else { return }
        let chosen = options
        // Allocate every output name up front, serially, before the concurrent run — two inputs
        // sharing a basename would otherwise both claim `<name>-ocr.pdf` and the second job's
        // atomic rename would fail (a purely on-disk check races under concurrency). Matches
        // CompressViewModel; each job then looks up its pre-reserved, unique destination.
        var reserved = Set<String>()
        var outputs: [ToolJob.ID: URL] = [:]
        for job in queue.jobs {
            outputs[job.id] = FileNaming.output(for: job.url, suffix: "ocr", folder: nil, reserving: &reserved)
        }
        isRunning = true
        Task {
            // A modest concurrency cap: each in-flight file holds one 300-DPI page raster plus
            // its accumulated recognised runs (bounded by `OCREngine.maxRecognisedTextRuns`), so
            // 2 keeps the worst case at two files' worth while still overlapping I/O and
            // recognition.
            await queue.run({ job, report in
                // A missing reservation means `add` let a file into the batch after the up-front
                // allocation pass — fail this one job loudly rather than silently allocating a
                // second, racing name from inside the concurrent run (see
                // `MissingOutputReservationError`).
                guard let output = outputs[job.id] else {
                    throw MissingOutputReservationError()
                }
                let outcome = try await self.engine.ocr(job.url, to: output, options: chosen) { report($0) }
                // Two outcomes write no file: `.alreadySearchable`, and a run that recognised no
                // usable text anywhere (`.tooFaint`). Neither has anything to reveal.
                if outcome.ocr == .alreadySearchable || outcome.ocr == .tooFaint {
                    return JobResult(outcome)
                }
                return JobResult(outcome, outputURL: output)
            }, maxConcurrent: 2)
            isRunning = false
        }
    }

    /// Stop the batch: queued files stay queued and in-flight recognition is interrupted at its
    /// next page boundary, leaving no output (matches `CompressViewModel`). Without this a
    /// thousand-page scan could only be stopped by force-quitting the app.
    func cancel() {
        queue.cancel()
    }
}
