// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation

/// One completed (or cancelled-but-banked) pass through the queue (spec §6.9). Feeds the empty-state
/// history strip and the Recent-batches sheet.
struct HistoryBatch: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    /// Display name + URL of the batch's representative folder — the save destination when one was
    /// set, else the first file's own folder (`FileNaming.output`'s own nil-folder resolution: a
    /// batch with no destination delivers each file beside itself, so the first file's folder is the
    /// only single answer that matches what "Open folder" would actually reveal).
    let folderName: String
    let folderURL: URL
    /// Every file the batch touched — freshly queued rows and recompressed (armed) rows alike.
    let fileCount: Int
    /// nil exactly when the batch's (locked) Compress verb was off — there is no preset to name.
    let presetTitle: String?
    let compressOn: Bool
    let ocrOn: Bool
    /// Bytes saved, summed from compressed rows ONLY (spec §6.5's exclusions: a rescued or
    /// OCR-only-delivery row ships no `shipped` version and contributes nothing here, however many
    /// pages it made searchable — that fact lives in `searchableCount` instead).
    let savedBytes: Int
    /// Rows OCR made searchable, whatever else happened to them: a plain compressed+OCR row, a
    /// rescue, or a noGain+OCR sibling delivery all count here (spec §6.9's "one made searchable").
    let searchableCount: Int
    /// Rows that actually delivered a file — the "N" in the handoff's "4 of 5 files in Invoices"
    /// (screens 01/11). Never more than `fileCount`; less than it exactly when a row failed
    /// outright, or a cancel left some rows untouched.
    let successCount: Int
    /// One short human phrase naming the FIRST problem row's cause — nil when nothing
    /// failed. "one was password-locked" is the handoff's own copy (screens 01/11); the other two
    /// are recorded divergences the handoff has no string for, mirroring `RowInspection.metaLine`'s
    /// own `.unreadable`/`.compressFailed` fallthrough.
    let failureNote: String?
    /// At least one row in the batch was degraded (spec §6.5: rescued, tooFaint, cancelled-between-legs,
    /// a read failure after a compress delivery) — delivered, but not a clean full success.
    let partial: Bool
    /// At least one row in the batch failed outright (a problem row) — the frequency signal for
    /// systemic gs failures the spec names.
    let problem: Bool
    /// The user cancelled this run. A cancelled batch is recorded only when it banked at least one
    /// delivered file — see `QueueViewModel`'s recording site.
    let cancelled: Bool

    /// "N of M files in <folder>" when the batch delivered fewer files than it set out to
    /// (screens 01/11); plain "M files in <folder>" otherwise. Shared by the empty-state strip
    /// and the Recent-batches sheet — the same line, computed once.
    var displayTitle: String {
        guard successCount < fileCount else { return "\(QueueByteFormat.count(fileCount, "file")) in \(folderName)" }
        return "\(successCount) of \(QueueByteFormat.count(fileCount, "file")) in \(folderName)"
    }

    init(id: UUID = UUID(), date: Date = Date(), folderName: String, folderURL: URL,
         fileCount: Int, presetTitle: String?, compressOn: Bool, ocrOn: Bool,
         savedBytes: Int, searchableCount: Int, successCount: Int = 0, failureNote: String? = nil,
         partial: Bool, problem: Bool, cancelled: Bool) {
        self.id = id
        self.date = date
        self.folderName = folderName
        self.folderURL = folderURL
        self.fileCount = fileCount
        self.presetTitle = presetTitle
        self.compressOn = compressOn
        self.ocrOn = ocrOn
        self.savedBytes = savedBytes
        self.searchableCount = searchableCount
        self.successCount = successCount
        self.failureNote = failureNote
        self.partial = partial
        self.problem = problem
        self.cancelled = cancelled
    }

    // MARK: Codable — `successCount`/`failureNote` are additive: older on-disk v1 batches
    // predate them, so decode defaults rather than failing (schema stays version 1, spec §6.9).
    private enum CodingKeys: String, CodingKey {
        case id, date, folderName, folderURL, fileCount, presetTitle, compressOn, ocrOn,
             savedBytes, searchableCount, successCount, failureNote, partial, problem, cancelled
    }

    /// A cap on the display strings decoded from disk: `history.json` is a trust boundary (it can
    /// be hand-edited or corrupted) and neither `folderName` nor `failureNote` has any other bound
    /// before reaching user-visible copy.
    static let maxDisplayStringLength = 200

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        folderName = String(try container.decode(String.self, forKey: .folderName)
            .prefix(Self.maxDisplayStringLength))
        let decodedFolderURL = try container.decode(URL.self, forKey: .folderURL)
        // `folderURL` reaches `NSWorkspace.open`/`activateFileViewerSelecting` unchanged (screen
        // 01/11's "Open folder"); a tampered on-disk envelope naming a non-file URL would dispatch
        // to whatever handler that scheme has — the same "hostile API response" class
        // `UpdateChecker.parseRelease` already pins its own remote-controlled URL against.
        guard decodedFolderURL.isFileURL else {
            throw DecodingError.dataCorruptedError(forKey: .folderURL, in: container,
                                                    debugDescription: "folderURL must be a file URL")
        }
        folderURL = decodedFolderURL
        fileCount = try container.decode(Int.self, forKey: .fileCount)
        presetTitle = try container.decodeIfPresent(String.self, forKey: .presetTitle)
        compressOn = try container.decode(Bool.self, forKey: .compressOn)
        ocrOn = try container.decode(Bool.self, forKey: .ocrOn)
        savedBytes = try container.decode(Int.self, forKey: .savedBytes)
        searchableCount = try container.decode(Int.self, forKey: .searchableCount)
        successCount = try container.decodeIfPresent(Int.self, forKey: .successCount) ?? 0
        failureNote = try container.decodeIfPresent(String.self, forKey: .failureNote)
            .map { String($0.prefix(Self.maxDisplayStringLength)) }
        partial = try container.decode(Bool.self, forKey: .partial)
        problem = try container.decode(Bool.self, forKey: .problem)
        cancelled = try container.decode(Bool.self, forKey: .cancelled)
    }
}

/// The recent-batches history (spec §6.9): a schema-versioned JSON file under Application
/// Support, distinct from `RunnerUpStore`'s cache root (that tree is purged at quit — this one
/// is exactly the persisted state R15's exception does not cover). Owns the lifetime savings
/// counter, which survives `clearList()` because the empty-state and sheet copy both promise it
/// does ("saved since you installed Toolbox").
///
/// @MainActor: constructed and driven by `QueueViewModel`; `batches`/`lifetimeSavedBytes` are
/// read by SwiftUI views on the main actor.
@MainActor
final class HistoryStore: ObservableObject {
    /// Newest-first, months of heavy use at trivial size — a hard bound against unbounded growth.
    static let retentionLimit = 200
    private static let currentVersion = 1

    @Published private(set) var batches: [HistoryBatch] = []
    @Published private(set) var lifetimeSavedBytes: Int = 0

    private let fileURL: URL

    /// The on-disk envelope (spec §6.9): `{"version":1,…}`. A foreign or absent/corrupt version
    /// starts empty in memory and is NEVER written back until the next `record()` — so a file from
    /// a future version of the app is left untouched on disk rather than being clobbered by an
    /// empty one the moment this launch happens to read it.
    private struct Envelope: Codable {
        let version: Int
        let batches: [HistoryBatch]
        let lifetimeSavedBytes: Int
    }

    /// The production directory (Application Support/Toolbox), shared by the instance's default
    /// location and available for callers that need it without an instance.
    nonisolated static var productionDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        return support.appendingPathComponent("Toolbox", isDirectory: true)
    }

    /// `directory` is the RunnerUpStore `rootOverride` test-seam pattern: nil resolves to the
    /// production Application Support location; every test passes a temp directory so no test
    /// ever touches the developer's real `history.json`.
    init(directory: URL? = nil) {
        let root = directory ?? Self.productionDirectory
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion else {
            return   // absent, corrupt or foreign — start empty, leave the file on disk untouched
        }
        // The retention cap is otherwise enforced only on write (`record(_:)`); a decoded envelope
        // is a trust boundary too (hand-edited or corrupted on disk), so it gets the same bound.
        batches = Array(envelope.batches.prefix(Self.retentionLimit))
        lifetimeSavedBytes = envelope.lifetimeSavedBytes
    }

    /// Record a completed (or cancelled-but-banked) batch: prepend (newest-first), trim to the
    /// retention cap, and fold its saving into the lifetime counter — which never shrinks here,
    /// even past the cap, because the counter is a running total, not a sum over `batches`.
    func record(_ batch: HistoryBatch) {
        batches.insert(batch, at: 0)
        if batches.count > Self.retentionLimit {
            batches.removeLast(batches.count - Self.retentionLimit)
        }
        lifetimeSavedBytes += batch.savedBytes
        persist()
    }

    /// "Clear list" (spec §6.9): empties `batches` only — `lifetimeSavedBytes` survives, matching
    /// the sheet's own promise that clearing it doesn't delete any files (or the running total).
    func clearList() {
        batches = []
        persist()
    }

    /// `batches` grouped by calendar day, newest day first, each day's batches in their existing
    /// newest-first order — the sheet's TODAY/YESTERDAY/date labelling is a rendering concern
    /// applied to the returned days, not this store's.
    var groupedByDay: [(day: Date, batches: [HistoryBatch])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [HistoryBatch]] = [:]
        for batch in batches {
            let day = calendar.startOfDay(for: batch.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(batch)
        }
        return order.map { (day: $0, batches: byDay[$0] ?? []) }
    }

    private func persist() {
        let envelope = Envelope(version: Self.currentVersion, batches: batches,
                                lifetimeSavedBytes: lifetimeSavedBytes)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
