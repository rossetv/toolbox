// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// Which engine leg produced a version. `.plain` covers every non-MRC engine result — the
/// Ghostscript output and the Rung-2 CCITT rebuild alike — because the only distinction the
/// estimate calibration needs (R16) is whether the MRC leg shipped this version.
enum EngineVariant: Equatable {
    case mrc
    case plain
    /// The untouched input, parked when the gs leg bloated and there was nothing legitimate to
    /// offer as an alternative (R6/R7).
    case original
}

/// One version of a row's file. The preset lives HERE, not on the job: a later batch at a
/// different preset must never rewrite a finished row's preset (R14).
struct FileVersion: Equatable {
    let url: URL
    let bytes: Int
    let preset: CompressPreset
    let variant: EngineVariant
}

/// The two parked slots a row can hold. The shipped version has no slot — it is the user's
/// delivered file and is never discarded.
enum VersionSlot: Equatable {
    /// This run's engine runner-up (the heavy/gs race's loser).
    case runnerUp
    /// The ONE previous version a recompress parked (D3).
    case previous
}

/// Every version a row knows about, plus the original size every aggregate is measured against.
struct RowVersions: Equatable {
    /// The input's size — the `before` behind every badge, pill and banner total.
    let originalBytes: Int
    /// The preset of the row's most recent COMPLETED attempt (a shipped result or a no-gain). A
    /// FAILED attempt never records here, so a transient failure stays retryable at the same
    /// preset rather than silently disarming the row (R1).
    var lastAttemptPreset: CompressPreset
    /// The user-visible file. Absent on a row that has shipped nothing (a no-gain row).
    var shipped: FileVersion?
    var runnerUp: FileVersion?
    var previous: FileVersion?

    /// The row's preset (R1): the shipped version's where one exists, else the last attempt's.
    var rowPreset: CompressPreset { shipped?.preset ?? lastAttemptPreset }

    /// The popover's cards, in order: current, this run's alternative, the previous version. The
    /// current card carries no slot — there is nothing to switch to from itself.
    var cards: [(slot: VersionSlot?, version: FileVersion)] {
        var out: [(slot: VersionSlot?, version: FileVersion)] = []
        if let shipped { out.append((nil, shipped)) }
        if let runnerUp { out.append((.runnerUp, runnerUp)) }
        if let previous { out.append((.previous, previous)) }
        return out
    }

    var count: Int { cards.count }

    /// The row's capsule label (R15). Today's dynamic family is preserved while the runner-up is
    /// the only parked version — a switched row keeps its honest label — and the title becomes
    /// "Versions" as soon as a previous version joins it.
    var capsuleTitle: String {
        if previous != nil { return "Versions" }
        switch shipped?.variant {
        case .mrc: return "Heavy compression"
        case .original: return "Original"
        default: return "Normal compression"
        }
    }
}

/// The display authority for every row's versions (R14), and the only path that discards a parked
/// file. Replacing or dropping a slot discards the file it held at that moment — never at quit —
/// so the session cache cannot grow with superseded versions (D6/R18).
/// @MainActor: owned and driven by `CompressViewModel`.
@MainActor
final class VersionStore {
    private let cache: RunnerUpStore
    private var rows: [ToolJob.ID: RowVersions] = [:]

    init(cache: RunnerUpStore) {
        self.cache = cache
    }

    func versions(for id: ToolJob.ID) -> RowVersions? { rows[id] }

    /// Record a completed attempt's versions wholesale (the batch-ingest path). Any parked file the
    /// old entry held and the new one does not is discarded here.
    func record(_ versions: RowVersions, for id: ToolJob.ID) {
        let superseded = Self.parkedURLs(of: rows[id]).subtracting(Self.parkedURLs(of: versions))
        rows[id] = versions
        for url in superseded { cache.discard(url) }
    }

    /// Replace one parked slot, discarding the file the old occupant held (R14).
    func setSlot(_ slot: VersionSlot, to version: FileVersion?, for id: ToolJob.ID) {
        guard var row = rows[id] else { return }
        let old = slot == .runnerUp ? row.runnerUp : row.previous
        switch slot {
        case .runnerUp: row.runnerUp = version
        case .previous: row.previous = version
        }
        rows[id] = row
        if let old, old.url != version?.url { cache.discard(old.url) }
    }

    /// Land a committed recompress: the new shipped version, and the preset it was produced at.
    func setShipped(_ version: FileVersion, for id: ToolJob.ID) {
        guard var row = rows[id] else { return }
        row.shipped = version
        row.lastAttemptPreset = version.preset
        rows[id] = row
    }

    /// Record a completed attempt that shipped nothing (a no-gain recompress), so the row's preset
    /// follows its most recent attempt (R1).
    func recordAttempt(_ preset: CompressPreset, for id: ToolJob.ID) {
        guard var row = rows[id] else { return }
        row.lastAttemptPreset = preset
        rows[id] = row
    }

    /// The switch: `RunnerUpStore` exchanges the two files' CONTENTS in place, so the URLs stay
    /// exactly where they are and only the descriptions move between the slots.
    func swapShipped(with slot: VersionSlot, for id: ToolJob.ID) {
        guard var row = rows[id], let shipped = row.shipped else { return }
        guard let parked = slot == .runnerUp ? row.runnerUp : row.previous else { return }
        row.shipped = FileVersion(url: shipped.url, bytes: parked.bytes,
                                  preset: parked.preset, variant: parked.variant)
        let demoted = FileVersion(url: parked.url, bytes: shipped.bytes,
                                  preset: shipped.preset, variant: shipped.variant)
        switch slot {
        case .runnerUp: row.runnerUp = demoted
        case .previous: row.previous = demoted
        }
        rows[id] = row
    }

    /// Drop a row, discarding every parked file it held. The shipped file is the user's delivered
    /// output and is never touched.
    func discardRow(_ id: ToolJob.ID) {
        for url in Self.parkedURLs(of: rows[id]) { cache.discard(url) }
        rows[id] = nil
    }

    /// Prune to the live rows. The ONLY removal path alongside `discardRow`: filtering the
    /// dictionary without discarding the files would leak every parked version of every row that
    /// left the queue.
    func retain(only liveIDs: Set<ToolJob.ID>) {
        for id in Array(rows.keys) where !liveIDs.contains(id) { discardRow(id) }
    }

    /// Reserve the cache name a parked previous version will take, through the same serial
    /// allocator as every batch output (R11).
    func reservePreviousURL(for input: URL, reserving reserved: inout Set<String>) -> URL {
        cache.reserveURL(for: input, suffix: "previous", reserving: &reserved)
    }

    private static func parkedURLs(of row: RowVersions?) -> Set<URL> {
        Set([row?.runnerUp?.url, row?.previous?.url].compactMap { $0 })
    }
}
