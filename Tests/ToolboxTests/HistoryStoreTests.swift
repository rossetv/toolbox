// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

/// `HistoryStore` (spec §6.9): the recent-batches history, schema-versioned on disk, distinct
/// from `RunnerUpStore`'s cache root (purged at quit) — this one is the persisted exception.
/// Every test below passes a temp directory: never the developer's real `history.json`.
@MainActor
final class HistoryStoreTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func batch(savedBytes: Int = 100, date: Date = Date(),
                       folderName: String = "Contracts", successCount: Int = 3,
                       failureNote: String? = nil) -> HistoryBatch {
        HistoryBatch(date: date, folderName: folderName,
                    folderURL: URL(fileURLWithPath: "/tmp/\(folderName)"),
                    fileCount: 3, presetTitle: "Balanced", compressOn: true, ocrOn: false,
                    savedBytes: savedBytes, searchableCount: 0,
                    successCount: successCount, failureNote: failureNote,
                    partial: false, problem: false, cancelled: false)
    }

    // MARK: round-trip

    func testRoundTrip() throws {
        let root = try tempRoot()
        let store = HistoryStore(directory: root)
        let entry = batch(savedBytes: 4_096)
        store.record(entry)

        let reloaded = HistoryStore(directory: root)
        XCTAssertEqual(reloaded.batches, [entry])
        XCTAssertEqual(reloaded.lifetimeSavedBytes, 4_096)
    }

    /// `successCount`/`failureNote` (F6b) round-trip like every other field — a batch with a
    /// recorded failure note survives encode/decode intact.
    func testRoundTripPreservesSuccessCountAndFailureNote() throws {
        let root = try tempRoot()
        let store = HistoryStore(directory: root)
        let entry = HistoryBatch(folderName: "Invoices", folderURL: URL(fileURLWithPath: "/tmp/Invoices"),
                                 fileCount: 5, presetTitle: "Balanced", compressOn: true, ocrOn: false,
                                 savedBytes: 1_000, searchableCount: 0,
                                 successCount: 4, failureNote: "one was password-locked",
                                 partial: false, problem: true, cancelled: false)
        store.record(entry)

        let reloaded = HistoryStore(directory: root)
        let decoded = try XCTUnwrap(reloaded.batches.first)
        XCTAssertEqual(decoded.successCount, 4)
        XCTAssertEqual(decoded.failureNote, "one was password-locked")
        XCTAssertEqual(decoded, entry)
    }

    /// The schema stays version 1 (unshipped): `successCount`/`failureNote` are additive, so an
    /// on-disk batch recorded before F6b (missing both keys) must still decode — defaulting to 0
    /// and nil — rather than corrupting the whole envelope. Built by encoding a real batch (so
    /// `Date`/`URL`'s own encoding is exactly what production writes) and then stripping the two
    /// new keys, rather than hand-guessing their on-disk shape.
    func testDecodeDefaultsSuccessCountAndFailureNoteWhenAbsent() throws {
        let root = try tempRoot()
        let store = HistoryStore(directory: root)
        store.record(batch(savedBytes: 500))
        let fileURL = root.appendingPathComponent("history.json")

        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var batches = try XCTUnwrap(envelope["batches"] as? [[String: Any]])
        batches[0]["successCount"] = nil
        batches[0]["failureNote"] = nil
        envelope["batches"] = batches
        try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL)

        let reloaded = HistoryStore(directory: root)
        let decoded = try XCTUnwrap(reloaded.batches.first)
        XCTAssertEqual(decoded.successCount, 0)
        XCTAssertNil(decoded.failureNote)
        XCTAssertEqual(reloaded.lifetimeSavedBytes, 500)
    }

    /// Two batches: newest-first ordering, and the lifetime counter is a running SUM, never
    /// reset by anything short of `clearList()` not existing at all.
    func testMultipleBatchesAreNewestFirstAndLifetimeAccumulates() throws {
        let root = try tempRoot()
        let store = HistoryStore(directory: root)
        let first = batch(savedBytes: 100)
        let second = batch(savedBytes: 200)
        store.record(first)
        store.record(second)

        XCTAssertEqual(store.batches.map(\.id), [second.id, first.id])
        XCTAssertEqual(store.lifetimeSavedBytes, 300)
    }

    // MARK: clear list (spec §6.9)

    func testClearListPreservesLifetime() throws {
        let root = try tempRoot()
        let store = HistoryStore(directory: root)
        store.record(batch(savedBytes: 500))

        store.clearList()

        XCTAssertTrue(store.batches.isEmpty)
        XCTAssertEqual(store.lifetimeSavedBytes, 500, "lifetime survives clearing the list")

        // Persisted too — a relaunch must not resurrect the cleared list or forget the lifetime total.
        let reloaded = HistoryStore(directory: root)
        XCTAssertTrue(reloaded.batches.isEmpty)
        XCTAssertEqual(reloaded.lifetimeSavedBytes, 500)
    }

    // MARK: retention (spec §6.9: newest 200)

    func testRetentionTrimsToTwoHundredKeepingTheNewest() throws {
        let root = try tempRoot()
        let store = HistoryStore(directory: root)
        var recorded: [HistoryBatch] = []
        for i in 0..<(HistoryStore.retentionLimit + 1) {
            let entry = batch(savedBytes: i)
            recorded.append(entry)
            store.record(entry)
        }

        XCTAssertEqual(store.batches.count, HistoryStore.retentionLimit)
        // Newest-first: the very first recorded batch (oldest) must have fallen off the end.
        XCTAssertEqual(store.batches.first?.id, recorded.last?.id)
        XCTAssertFalse(store.batches.contains { $0.id == recorded.first!.id },
                       "the oldest batch must be trimmed past the retention cap")
        // The lifetime counter is unaffected by trimming — it is a running total, not a sum over
        // the retained list.
        let expectedLifetime = (0...HistoryStore.retentionLimit).reduce(0, +)
        XCTAssertEqual(store.lifetimeSavedBytes, expectedLifetime)
    }

    /// The retention cap must also apply to a decoded envelope, not just to `record(_:)`: a
    /// hand-edited or corrupted `history.json` holding more than `retentionLimit` batches must not
    /// be adopted wholesale.
    func testDecodingClampsAnOverCapEnvelopeToTheRetentionLimit() throws {
        let root = try tempRoot()
        let fileURL = root.appendingPathComponent("history.json")
        let overCap = (0..<(HistoryStore.retentionLimit + 5)).map { batch(savedBytes: $0) }
        var envelope: [String: Any] = ["version": 1, "lifetimeSavedBytes": 0]
        envelope["batches"] = try overCap.map { batch -> [String: Any] in
            let data = try JSONEncoder().encode(batch)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL)

        let store = HistoryStore(directory: root)
        XCTAssertEqual(store.batches.count, HistoryStore.retentionLimit)
    }

    /// `folderURL` crosses a trust boundary (the on-disk envelope) on its way to
    /// `NSWorkspace.open`/`activateFileViewerSelecting` — a non-file URL must fail to decode
    /// rather than being handed to those APIs, which dispatch any scheme's registered handler.
    func testDecodingRejectsANonFileFolderURL() throws {
        let root = try tempRoot()
        let fileURL = root.appendingPathComponent("history.json")
        let entry = batch()
        let data = try JSONEncoder().encode(entry)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict["folderURL"] = "https://example.com/evil"
        let envelope: [String: Any] = ["version": 1, "batches": [dict], "lifetimeSavedBytes": 0]
        try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL)

        let store = HistoryStore(directory: root)
        XCTAssertTrue(store.batches.isEmpty, "a non-file folderURL must fail the whole envelope, not be adopted")
    }

    // MARK: day grouping

    func testGroupedByDaySeparatesCalendarDaysNewestFirst() throws {
        let root = try tempRoot()
        let store = HistoryStore(directory: root)
        let calendar = Calendar.current
        // Anchored at noon (never Date()) so the -2h "earlier" batch below can never cross a
        // calendar-day boundary regardless of the wall-clock time the suite runs at.
        let today = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let todayEarlier = batch(date: calendar.date(byAdding: .hour, value: -2, to: today)!)
        let todayLater = batch(date: today)
        let yesterdayBatch = batch(date: yesterday)
        // Recorded oldest-first; `batches` itself keeps newest-first via `record`'s prepend.
        store.record(yesterdayBatch)
        store.record(todayEarlier)
        store.record(todayLater)

        let grouped = store.groupedByDay
        XCTAssertEqual(grouped.count, 2, "today's two batches and yesterday's one form two days")
        XCTAssertEqual(grouped[0].batches.map(\.id), [todayLater.id, todayEarlier.id],
                       "today's day-group keeps the newest-first order, today first")
        XCTAssertEqual(grouped[1].batches.map(\.id), [yesterdayBatch.id])
    }

    // MARK: schema version (spec §6.9: foreign version → empty start, never overwritten early)

    func testCorruptFileStartsEmpty() throws {
        let root = try tempRoot()
        try Data("not json".utf8).write(to: root.appendingPathComponent("history.json"))

        let store = HistoryStore(directory: root)

        XCTAssertTrue(store.batches.isEmpty)
        XCTAssertEqual(store.lifetimeSavedBytes, 0)
    }

    func testForeignVersionStartsEmptyAndDoesNotOverwriteUntilNextRecord() throws {
        let root = try tempRoot()
        let fileURL = root.appendingPathComponent("history.json")
        let foreignJSON = """
        {"version": 99, "batches": [], "lifetimeSavedBytes": 123456, "somethingFutureVersionsAdded": true}
        """
        try Data(foreignJSON.utf8).write(to: fileURL)
        let originalBytes = try Data(contentsOf: fileURL)

        let store = HistoryStore(directory: root)
        XCTAssertTrue(store.batches.isEmpty)
        XCTAssertEqual(store.lifetimeSavedBytes, 0, "never adopt a foreign version's fields")

        // Never overwrite until the next record: the foreign file must survive untouched.
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        store.record(batch(savedBytes: 10))
        let afterRecord = try Data(contentsOf: fileURL)
        XCTAssertNotEqual(afterRecord, originalBytes,
                          "a record after the foreign read now owns the file")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: afterRecord) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
    }

    func testMissingFileStartsEmpty() throws {
        let root = try tempRoot()
        let store = HistoryStore(directory: root)
        XCTAssertTrue(store.batches.isEmpty)
        XCTAssertEqual(store.lifetimeSavedBytes, 0)
    }
}
