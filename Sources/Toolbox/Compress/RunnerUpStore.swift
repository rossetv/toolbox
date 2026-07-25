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

    /// Reserve a cache URL for one of a job's parked versions, via the same serial allocator as
    /// every batch output (C4). `suffix` keeps a row's runner-up and its parked previous version
    /// (R14) apart in the shared cache root. Call in the view-model's up-front reservation loop.
    func reserveURL(for input: URL, suffix: String = "runner-up",
                    reserving reserved: inout Set<String>) -> URL {
        FileNaming.output(for: input, suffix: suffix, folder: root, reserving: &reserved)
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

    /// The shared three-step algorithm behind both `switchVersions` and `promote`: park the
    /// shipped file beside itself under a dot-temp name (never straight into the cache root — see
    /// `promote`'s doc for why), move `incoming` into the shipped slot, and on success relocate the
    /// park into `destination`; on failure to promote, restore the park back to `shipped`.
    /// `tempPrefix` keeps each caller's dot-temp idiom distinguishable in a crash-leftover sweep.
    private func performSwap(incoming: URL, shipped: URL, destination: URL, tempPrefix: String) throws {
        let fm = FileManager.default
        let temp = shipped.deletingLastPathComponent()
            .appendingPathComponent(".toolbox-\(tempPrefix)-\(UUID().uuidString).pdf")
        try fm.moveItem(at: shipped, to: temp)            // park the shipped version
        do {
            try fm.moveItem(at: incoming, to: shipped)    // promote the incoming version
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
                    _ = try fm.replaceItemAt(shipped, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: shipped)
                }
            } catch {
                throw SwitchError.shippedStranded(parked: temp)
            }
            throw error
        }
        do {
            try fm.moveItem(at: temp, to: destination)    // relocate the parked version into the slot
        } catch {
            // The switch already succeeded from the user's perspective — shipped holds the new
            // content. Discard the stranded parked file rather than throw; a missing runner-up is
            // already a designed-for state (R10's re-run path).
            try? fm.removeItem(at: temp)
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
        try performSwap(incoming: runnerUp, shipped: shipped, destination: runnerUp, tempPrefix: "swap")
    }

    /// The R12 recompress commit: park the currently-shipped file, promote `fresh` into its place,
    /// then move the parked version into the cache slot `parked` names.
    ///
    /// **Three steps, exactly as `switchVersions` does it, and for the same reason.** The version
    /// the user currently has is parked into a `.toolbox-<uuid>` dot-temp **beside the shipped
    /// file** — never straight into `parked`, which lives in the cache root. Two reasons, both
    /// load-bearing: the cache root is swept at launch, so a crash in this window with the user's
    /// only delivered copy sitting in it would destroy that copy; and the cache root is frequently
    /// on a different volume from the output folder, where `moveItem` silently degrades to a
    /// copy-then-delete and the "atomic" park is no longer atomic. The dot-temp idiom matches the
    /// engine's, so a crash leftover is the already-accepted residual pattern.
    ///
    /// Failure shapes, in the order the steps run:
    /// 1. **Park fails** — nothing has moved; an ordinary throw, shipped file untouched.
    /// 2. **Promote fails** — the park is undone by the same documented restore `switchVersions`
    ///    uses, then the promote's own error is rethrown. If even the restore fails,
    ///    `SwitchError.shippedStranded` carries the dot-temp path, because the user's file is no
    ///    longer where they left it and nothing else will ever look for it there.
    /// 3. **Reaching the cache slot fails** — the commit has ALREADY succeeded from the user's
    ///    point of view (their file holds the new version), so this **does not throw**: the parked
    ///    copy is discarded instead of being stranded under a hidden dot-name. The caller therefore
    ///    must not assume a file exists at `parked` after a successful return — see `commit` in the
    ///    view model, and `useVersion`'s already-designed-for "that version is no longer available"
    ///    path (a `previous` slot whose file is gone is an existing, handled state, not a new one).
    ///
    /// The old version therefore survives every path on which the promotion did NOT happen, which
    /// is what lets an armed row keep its result when a recompress fails.
    func promote(fresh: URL, to shipped: URL, parking parked: URL) throws {
        try performSwap(incoming: fresh, shipped: shipped, destination: parked, tempPrefix: "promote")
    }

    func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
