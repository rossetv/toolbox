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

    /// The production cache directory (caches/Toolbox/runner-ups), shared by the instance's
    /// default root and the static quit-time cleanup below.
    nonisolated static var productionRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Toolbox/runner-ups", isDirectory: true)
    }

    /// rootOverride is for tests; production uses caches/Toolbox/runner-ups.
    init(rootOverride: URL? = nil) {
        root = rootOverride ?? Self.productionRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Empty the cache directory without needing an instance — quit must not depend on which
    /// view-models exist. `root` defaults to the production directory; tests pass a temp root.
    nonisolated static func removeAllOnDisk(root: URL = RunnerUpStore.productionRoot) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents {
            try? fm.removeItem(at: url)
        }
    }

    /// Sweep everything left by a previous run (crash leftovers). Call once at start-up.
    func sweepStale() {
        Self.removeAllOnDisk(root: root)
    }

    /// Reserve a cache URL for a job's runner-up, via the same serial allocator as every
    /// batch output (C4). Call in the view-model's up-front reservation loop.
    func reserveURL(for input: URL, reserving reserved: inout Set<String>) -> URL {
        FileNaming.output(for: input, suffix: "runner-up", folder: root, reserving: &reserved)
    }

    /// Atomically exchange the shipped file's content with the runner-up's (the UI switch).
    ///
    /// Throws only when the switch did not happen (shipped file unchanged). A successful switch
    /// never throws; if the demoted version cannot take the cache slot it is discarded, leaving
    /// the runner-up absent — callers already handle a missing runner-up.
    func switchVersions(shipped: URL, runnerUp: URL) throws {
        let fm = FileManager.default
        // Parked alongside the shipped file, not in the sweep-on-launch cache dir: a crash in
        // this window must not destroy the user's already-shipped output. This mirrors the
        // engine's `.toolbox-<uuid>` dot-temp idiom, so an orphaned park file left after a crash
        // matches the accepted residual pattern elsewhere in the app.
        let parked = shipped.deletingLastPathComponent()
            .appendingPathComponent(".toolbox-swap-\(UUID().uuidString).pdf")
        try fm.moveItem(at: shipped, to: parked)          // park the shipped version
        do {
            try fm.moveItem(at: runnerUp, to: shipped)    // promote the runner-up
        } catch {
            try? fm.moveItem(at: parked, to: shipped)     // restore; the user's file survives
            throw error
        }
        do {
            try fm.moveItem(at: parked, to: runnerUp)     // demote the old winner into the cache slot
        } catch {
            // The switch already succeeded from the user's perspective — shipped holds the new
            // content. Discard the stranded parked file rather than throw; a missing runner-up is
            // already a designed-for state (R10's re-run path).
            try? fm.removeItem(at: parked)
        }
    }

    func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
