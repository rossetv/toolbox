// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Owns the app-managed cache directory holding losing compression versions (spec R15 — the
/// documented exception to "no persisted app state", bounded to crash-leftover sweep).
/// @MainActor: owned and driven by CompressViewModel.
@MainActor
final class RunnerUpStore {
    private let root: URL

    /// rootOverride is for tests; production uses caches/Toolbox/runner-ups.
    init(rootOverride: URL? = nil) {
        if let rootOverride {
            root = rootOverride
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            root = caches.appendingPathComponent("Toolbox/runner-ups", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Sweep everything left by a previous run (crash leftovers). Call once at start-up.
    func sweepStale() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents {
            try? fm.removeItem(at: url)
        }
    }

    /// Reserve a cache URL for a job's runner-up, via the same serial allocator as every
    /// batch output (C4). Call in the view-model's up-front reservation loop.
    func reserveURL(for input: URL, reserving reserved: inout Set<String>) -> URL {
        FileNaming.output(for: input, suffix: "runner-up", folder: root, reserving: &reserved)
    }

    /// Atomically exchange the shipped file's content with the runner-up's (the UI switch).
    /// Either both moves land or the shipped file is restored — never a lost output.
    func switchVersions(shipped: URL, runnerUp: URL) throws {
        let fm = FileManager.default
        let parked = root.appendingPathComponent(".swap-\(UUID().uuidString).pdf")
        try fm.moveItem(at: shipped, to: parked)          // park the shipped version
        do {
            try fm.moveItem(at: runnerUp, to: shipped)    // promote the runner-up
        } catch {
            try? fm.moveItem(at: parked, to: shipped)     // restore; the user's file survives
            throw error
        }
        try fm.moveItem(at: parked, to: runnerUp)         // demote the old winner into the cache slot
    }

    func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func discardAll() {
        sweepStale()
    }
}
