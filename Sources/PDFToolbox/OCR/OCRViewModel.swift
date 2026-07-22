// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
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
        cancellable = queue.$jobs
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.jobs = $0 }
    }

    var hasQueuedWork: Bool {
        jobs.contains { if case .queued = $0.state { return true } else { return false } }
    }

    var canRun: Bool { !isRunning && hasQueuedWork }

    var pageCandidateCount: Int { jobs.count }

    func add(_ urls: [URL]) {
        queue.add(urls.filter { $0.pathExtension.lowercased() == "pdf" })
    }

    func clearFinished() {
        queue.removeCompleted()
    }

    func run() {
        guard !isRunning else { return }
        let chosen = options
        isRunning = true
        Task {
            // A modest concurrency cap: each in-flight file holds one 300-DPI page raster, so 2
            // bounds memory while still overlapping I/O and recognition.
            await queue.run({ job, report in
                let output = FileNaming.output(for: job.url, suffix: "ocr", folder: nil)
                return try await self.engine.ocr(job.url, to: output, options: chosen) { report($0) }
            }, maxConcurrent: 2)
            isRunning = false
        }
    }
}
