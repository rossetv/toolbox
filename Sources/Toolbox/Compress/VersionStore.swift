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

/// A row's DISPLAY identity, deliberately distinct from `VersionSlot`: the popover's radio list also
/// names the delivered file and the untouched original, neither of which is ever parked, so the
/// parked cap stays at two slots (spec §5's version-cap ruling).
enum VersionCardKey: Hashable {
    /// The file the user has right now.
    case shipped
    case runnerUp
    case previous
    /// The untouched input, referenced where it already lives and never copied into the cache.
    case originalReference
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
    /// The untouched input, behind the popover's Original reference row. The file is referenced in
    /// its own folder — never parked, never appended to, never discarded by this store.
    var originalURL: URL?
    /// Per-card searchability, populated ONLY when the OCR leg ran for this row. Empty therefore
    /// means "no OCR happened here", and the popover shows no searchability subtitle in either
    /// direction (spec §6.4) — reading this map with a `?? false` default would manufacture a claim
    /// the row has no evidence for.
    var searchableByCard: [VersionCardKey: Bool] = [:]

    /// The row's preset (R1): the shipped version's where one exists, else the last attempt's.
    var rowPreset: CompressPreset { shipped?.preset ?? lastAttemptPreset }

    /// The popover's radio list in screen order: the file in use, this run's alternative, the
    /// previous version, and the untouched original last.
    ///
    /// The Original row is SYNTHESISED from `originalURL` rather than stored, and is omitted in the
    /// three cases where it would list one file twice: no original recorded, the original is already
    /// what shipped (after a switch to it), or a parked slot already holds the `.original` variant
    /// (the gs leg bloated and there was nothing legitimate to offer — R6/R7).
    var cards: [(key: VersionCardKey, version: FileVersion)] {
        var out: [(key: VersionCardKey, version: FileVersion)] = []
        if let shipped { out.append((.shipped, shipped)) }
        if let runnerUp { out.append((.runnerUp, runnerUp)) }
        if let previous { out.append((.previous, previous)) }
        if let originalURL, shipped?.variant != .original,
           runnerUp?.variant != .original, previous?.variant != .original {
            out.append((.originalReference,
                        FileVersion(url: originalURL, bytes: originalBytes,
                                    preset: rowPreset, variant: .original)))
        }
        return out
    }

    var count: Int { cards.count }

    /// The capsule's label — the number of rows the popover lists (handoff screens 06/07).
    ///
    /// The capsule RENDERS only when a parked version exists (`runnerUp != nil || previous != nil`),
    /// never on `cards.count`: the always-present Original reference row puts every delivered row at
    /// two or more cards, while the renders show no capsule at all on a plain compressed row. Under
    /// that gate the count is always at least two, so there is no singular form to write.
    var capsuleTitle: String { "\(cards.count) versions" }
}

/// The display authority for every row's versions (R14), and the only path that discards a parked
/// file — with one documented exception: `QueueViewModel.rerunForSwitch` clears and
/// regenerates the runner-up FILE directly at its existing URL (never through `setSlot`, so the
/// row's `FileVersion` record — and the URL it names — is deliberately left standing across that
/// window, because the re-run is expected to recreate the same file the record already describes).
/// Everywhere else, replacing or dropping a slot discards the file it held at that moment — never
/// at quit — so the session cache cannot grow with superseded versions (D6/R18).
/// @MainActor: owned and driven by `QueueViewModel`.
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

    /// Record the untouched input, so the popover can offer it as the Original reference row.
    func setOriginalURL(_ url: URL, for id: ToolJob.ID) {
        guard var row = rows[id] else { return }
        row.originalURL = url
        rows[id] = row
    }

    /// Record one card's searchability from that file's own append result. Called only when the OCR
    /// leg ran: a card left unwritten carries no claim, which is what a compress-only row needs.
    func setSearchable(_ searchable: Bool, card: VersionCardKey, for id: ToolJob.ID) {
        guard var row = rows[id] else { return }
        row.searchableByCard[card] = searchable
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
        // The searchability flags describe the BYTES, so they travel with the descriptions —
        // leaving the old flag on the new file is the lie §6.4 forbids. Optional assignment
        // throughout: an absent flag stays absent, so a row whose OCR leg never ran comes out of a
        // switch claiming nothing.
        let key: VersionCardKey = slot == .runnerUp ? .runnerUp : .previous
        let shippedFlag = row.searchableByCard[.shipped]
        row.searchableByCard[.shipped] = row.searchableByCard[key]
        row.searchableByCard[key] = shippedFlag
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
