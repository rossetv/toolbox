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

    /// Why a switch could not be completed, in the one shape where the caller cannot simply retry.
    enum SwitchError: Error, LocalizedError {
        /// The runner-up could not be promoted *and* the parked shipped file could not be put
        /// back. The user's file is intact at `parked` — a hidden name nothing else ever looks
        /// for — so the path travels with the error rather than being swallowed.
        case shippedStranded(parked: URL)

        var errorDescription: String? {
            switch self {
            case .shippedStranded(let parked):
                return "The switch failed and the compressed file could not be put back. "
                     + "It is safe at \(parked.path)."
            }
        }
    }

    /// Atomically exchange the shipped file's content with the runner-up's (the UI switch).
    ///
    /// Throws only when the switch did not happen, in one of two shapes the caller must tell
    /// apart: any ordinary throw leaves the shipped file exactly as it was, whereas
    /// `SwitchError.shippedStranded` means the promotion failed AND the shipped file could not be
    /// restored — it survives at the park path the error names, and nothing else will look for it.
    /// A successful switch never throws; if the demoted version cannot take the cache slot it is
    /// discarded, leaving the runner-up absent — callers already handle a missing runner-up.
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
            // Restore on the documented path for each state: `shipped` is normally absent (we
            // just moved it out), so a plain `moveItem` restores it; if something recreated it
            // in this window (a sync client, the user) `replaceItemAt` swaps that impostor out
            // rather than throwing the restore away. Never `replaceItemAt` against an absent
            // destination — that happens to work today but is not documented behaviour.
            // If even the restore fails, the file is NOT where the user left it — say so, with
            // the park path, rather than reporting a mere failed switch.
            do {
                if fm.fileExists(atPath: shipped.path) {
                    _ = try fm.replaceItemAt(shipped, withItemAt: parked)
                } else {
                    try fm.moveItem(at: parked, to: shipped)
                }
            } catch {
                throw SwitchError.shippedStranded(parked: parked)
            }
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
