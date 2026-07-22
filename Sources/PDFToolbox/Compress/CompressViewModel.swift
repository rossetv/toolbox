// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Combine
import Foundation

/// Drives the Compress tool: owns the `ToolQueue`, the selected preset and the Rung-1
/// `CompressEngine`, and mirrors the queue's jobs so the view re-renders on state changes.
/// (Phase 0 is single-file/basic; batch, estimates and the output-folder picker are Track C.)
@MainActor
final class CompressViewModel: ObservableObject {
    @Published var preset: CompressPreset = .balanced
    @Published private(set) var jobs: [ToolJob] = []
    @Published private(set) var isRunning = false
    @Published private(set) var loadError: String?

    let queue = ToolQueue()
    private let engine: CompressEngine?
    private var cancellable: AnyCancellable?

    init() {
        if let runner = try? GhostscriptRunner() {
            engine = CompressEngine(runner: runner)
        } else {
            engine = nil
            loadError = "Ghostscript is missing from the app bundle — the app cannot compress."
        }
        cancellable = queue.$jobs
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.jobs = $0 }
    }

    var hasQueuedWork: Bool {
        jobs.contains { if case .queued = $0.state { return true } else { return false } }
    }

    var canCompress: Bool { engine != nil && !isRunning && hasQueuedWork }

    func add(_ urls: [URL]) {
        queue.add(urls.filter { $0.pathExtension.lowercased() == "pdf" })
    }

    func clearFinished() {
        queue.removeCompleted()
    }

    func compress() {
        guard let engine, !isRunning else { return }
        let chosen = preset
        isRunning = true
        Task {
            await queue.run({ job, report in
                let output = FileNaming.output(for: job.url, suffix: "compressed", folder: nil)
                return try await engine.compress(job.url, preset: chosen, to: output) { report($0) }
            }, maxConcurrent: 1)
            isRunning = false
        }
    }
}
