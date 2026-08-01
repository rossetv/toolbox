// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

/// `VersionStore` is the display authority for a row's versions (R14) and the ONLY path that
/// discards a parked file — a slot dropped without its file discarded is exactly the growing
/// cache D6 forbids.
@MainActor
final class VersionStoreTests: XCTestCase {

    private func makeStore() throws -> (VersionStore, RunnerUpStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("version-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = RunnerUpStore(rootOverride: root)
        return (VersionStore(cache: cache), cache, root)
    }

    private func file(_ root: URL, _ name: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// A second recompress replaces the previous slot and discards the file the old one held —
    /// at replacement time, not at quit (R14: "no cache leak").
    func testReplacingThePreviousSlotDiscardsTheSupersededFile() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let shipped = try file(root, "out.pdf", bytes: 100)
        let firstPrevious = try file(root, "out-previous.pdf", bytes: 300)
        let secondPrevious = try file(root, "out-previous-1.pdf", bytes: 200)

        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: shipped, bytes: 100, preset: .balanced,
                                                      variant: .plain),
                                 runnerUp: nil,
                                 previous: FileVersion(url: firstPrevious, bytes: 300,
                                                       preset: .maximumQuality, variant: .plain)),
                     for: id)

        store.setSlot(.previous, to: FileVersion(url: secondPrevious, bytes: 200,
                                                 preset: .balanced, variant: .plain), for: id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPrevious.path),
                       "the superseded previous version's file must be discarded at replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPrevious.path))
        XCTAssertEqual(store.versions(for: id)?.previous?.bytes, 200)
    }

    /// Dropping a row discards its parked files but never the user's delivered output.
    func testDiscardRowRemovesParkedFilesAndKeepsTheShippedFile() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let shipped = try file(root, "out.pdf", bytes: 100)
        let runnerUp = try file(root, "out-runner-up.pdf", bytes: 250)
        let previous = try file(root, "out-previous.pdf", bytes: 300)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: shipped, bytes: 100, preset: .balanced,
                                                      variant: .mrc),
                                 runnerUp: FileVersion(url: runnerUp, bytes: 250,
                                                       preset: .balanced, variant: .plain),
                                 previous: FileVersion(url: previous, bytes: 300,
                                                       preset: .maximumQuality, variant: .plain)),
                     for: id)

        store.discardRow(id)

        XCTAssertNil(store.versions(for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runnerUp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shipped.path),
                      "the delivered output is the user's file and is never discarded")
    }

    /// Pruning to the live rows must DISCARD, not merely forget: a filtered dictionary leaks every
    /// parked file of every row that left the queue.
    func testRetainDiscardsTheFilesOfDroppedRows() throws {
        let (store, _, root) = try makeStore()
        let live = UUID(), dropped = UUID()
        let liveRunnerUp = try file(root, "live-runner-up.pdf", bytes: 10)
        let droppedRunnerUp = try file(root, "dropped-runner-up.pdf", bytes: 10)
        for (id, runnerUp) in [(live, liveRunnerUp), (dropped, droppedRunnerUp)] {
            store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                     shipped: nil,
                                     runnerUp: FileVersion(url: runnerUp, bytes: 10,
                                                           preset: .balanced, variant: .plain),
                                     previous: nil),
                         for: id)
        }

        store.retain(only: [live])

        XCTAssertTrue(FileManager.default.fileExists(atPath: liveRunnerUp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: droppedRunnerUp.path))
        XCTAssertNil(store.versions(for: dropped))
    }

    /// The switch exchanges the two files' CONTENTS in place, so the URLs stay put and only the
    /// descriptions move between the slots — the invariant every byte badge reads.
    func testSwapMovesDescriptionsBetweenSlotsAndLeavesURLsInPlace() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let shipped = try file(root, "out.pdf", bytes: 100)
        let previous = try file(root, "out-previous.pdf", bytes: 300)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .smallestSize,
                                 shipped: FileVersion(url: shipped, bytes: 100,
                                                      preset: .smallestSize, variant: .mrc),
                                 runnerUp: nil,
                                 previous: FileVersion(url: previous, bytes: 300,
                                                       preset: .balanced, variant: .plain)),
                     for: id)

        store.swapShipped(with: .previous, for: id)

        let row = try XCTUnwrap(store.versions(for: id))
        XCTAssertEqual(row.shipped?.url, shipped, "the delivered path never moves")
        XCTAssertEqual(row.shipped?.bytes, 300)
        XCTAssertEqual(row.shipped?.preset, .balanced)
        XCTAssertEqual(row.previous?.url, previous)
        XCTAssertEqual(row.previous?.bytes, 100)
        XCTAssertEqual(row.previous?.preset, .smallestSize)
        XCTAssertEqual(row.rowPreset, .balanced, "the row's preset follows the shipped version")
    }

    /// The capsule's label counts the popover's rows (handoff screens 06/07) — it no longer names a
    /// variant, so a switch cannot make it stale.
    func testCapsuleTitleCountsEveryCard() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let shipped = try file(root, "out.pdf", bytes: 100)
        let runnerUp = try file(root, "out-runner-up.pdf", bytes: 250)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: shipped, bytes: 100, preset: .balanced,
                                                      variant: .mrc),
                                 runnerUp: FileVersion(url: runnerUp, bytes: 250,
                                                       preset: .balanced, variant: .plain),
                                 previous: nil),
                     for: id)
        XCTAssertEqual(store.versions(for: id)?.capsuleTitle, "2 versions")

        store.swapShipped(with: .runnerUp, for: id)
        XCTAssertEqual(store.versions(for: id)?.capsuleTitle, "2 versions",
                       "a switch moves descriptions between rows; it never adds or removes one")

        store.setSlot(.previous, to: FileVersion(url: try file(root, "p.pdf", bytes: 5), bytes: 5,
                                                 preset: .maximumQuality, variant: .plain), for: id)
        XCTAssertEqual(store.versions(for: id)?.capsuleTitle, "3 versions")
        XCTAssertEqual(store.versions(for: id)?.count, 3)
    }

    /// The searchability flags describe the FILES, not the slots, so an instant switch must permute
    /// them along with the descriptions it moves — leaving the old flag on the new bytes is exactly
    /// the misrepresentation §6.4 forbids.
    func testSwapShippedPermutesSearchableFlags() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let shipped = try file(root, "out.pdf", bytes: 100)
        let runnerUp = try file(root, "out-runner-up.pdf", bytes: 250)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: shipped, bytes: 100, preset: .balanced,
                                                      variant: .mrc),
                                 runnerUp: FileVersion(url: runnerUp, bytes: 250,
                                                       preset: .balanced, variant: .plain),
                                 previous: nil),
                     for: id)
        store.setSearchable(true, card: .shipped, for: id)
        store.setSearchable(false, card: .runnerUp, for: id)

        store.swapShipped(with: .runnerUp, for: id)

        var row = try XCTUnwrap(store.versions(for: id))
        XCTAssertEqual(row.searchableByCard[.shipped], false,
                       "the flag follows the bytes: the file now in use carries no text layer")
        XCTAssertEqual(row.searchableByCard[.runnerUp], true)

        // A row whose OCR leg never ran carries no claim in either direction, and the swap must not
        // manufacture one — a `?? false` default anywhere in the permutation would.
        let bare = UUID()
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: try file(root, "b.pdf", bytes: 100),
                                                      bytes: 100, preset: .balanced, variant: .mrc),
                                 runnerUp: FileVersion(url: try file(root, "b-runner-up.pdf",
                                                                     bytes: 250),
                                                       bytes: 250, preset: .balanced,
                                                       variant: .plain),
                                 previous: nil),
                     for: bare)

        store.swapShipped(with: .runnerUp, for: bare)

        row = try XCTUnwrap(store.versions(for: bare))
        XCTAssertTrue(row.searchableByCard.isEmpty,
                      "an empty map means the OCR leg never ran; the swap must leave it empty")
    }

    /// The popover's last row is the untouched input, synthesised from `originalURL` rather than
    /// parked: the original is referenced where it already lives, so the parked cap stays at two.
    func testCardsIncludeOriginalReference() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let original = try file(root, "in.pdf", bytes: 900)
        let shipped = try file(root, "out.pdf", bytes: 100)
        let runnerUp = try file(root, "out-runner-up.pdf", bytes: 250)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: shipped, bytes: 100, preset: .balanced,
                                                      variant: .mrc),
                                 runnerUp: FileVersion(url: runnerUp, bytes: 250,
                                                       preset: .balanced, variant: .plain),
                                 previous: nil),
                     for: id)
        XCTAssertEqual(store.versions(for: id)?.cards.map(\.key), [.shipped, .runnerUp],
                       "no original recorded yet, so there is nothing to reference")

        store.setOriginalURL(original, for: id)

        let row = try XCTUnwrap(store.versions(for: id))
        XCTAssertEqual(row.cards.map(\.key), [.shipped, .runnerUp, .originalReference])
        let reference = try XCTUnwrap(row.cards.last?.version)
        XCTAssertEqual(reference.url, original)
        XCTAssertEqual(reference.bytes, 900, "the reference row states the input's own size")
        XCTAssertEqual(reference.variant, .original)
        XCTAssertEqual(reference.preset, row.rowPreset)
    }

    /// When a parked slot already holds the untouched input (the gs leg bloated, R6/R7), the
    /// reference row is suppressed — one file, one row, never listed twice.
    func testNoDuplicateRowWhenParkedVariantIsOriginal() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let original = try file(root, "in.pdf", bytes: 900)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: try file(root, "out.pdf", bytes: 100),
                                                      bytes: 100, preset: .balanced, variant: .mrc),
                                 runnerUp: FileVersion(url: try file(root, "parked.pdf", bytes: 900),
                                                       bytes: 900, preset: .balanced,
                                                       variant: .original),
                                 previous: FileVersion(url: try file(root, "p.pdf", bytes: 400),
                                                       bytes: 400, preset: .maximumQuality,
                                                       variant: .plain)),
                     for: id)
        store.setOriginalURL(original, for: id)

        let row = try XCTUnwrap(store.versions(for: id))
        XCTAssertEqual(row.cards.map(\.key), [.shipped, .runnerUp, .previous])
        XCTAssertEqual(row.capsuleTitle, "3 versions")
    }

    /// After a switch to the original, the shipped file IS the input — the reference row would be
    /// the same file a second time, so it is suppressed there too.
    func testOriginalReferenceHiddenWhenShippedIsOriginalDirect() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let original = try file(root, "in.pdf", bytes: 900)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: try file(root, "out.pdf", bytes: 900),
                                                      bytes: 900, preset: .balanced,
                                                      variant: .original),
                                 runnerUp: nil,
                                 previous: FileVersion(url: try file(root, "p.pdf", bytes: 100),
                                                       bytes: 100, preset: .balanced,
                                                       variant: .mrc)),
                     for: id)
        store.setOriginalURL(original, for: id)

        let row = try XCTUnwrap(store.versions(for: id))
        XCTAssertEqual(row.cards.map(\.key), [.shipped, .previous])
        XCTAssertEqual(row.capsuleTitle, "2 versions")
    }

    /// Both parked slots occupied (a consent-retained loser plus a recompress park) is the widest
    /// the popover ever gets: four rows including the reference, never five — the cap is on the
    /// SLOTS, and the display identity does not add one.
    func testConsentRetentionPlusPreviousParkStaysWithinCap() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let original = try file(root, "in.pdf", bytes: 900)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: try file(root, "out.pdf", bytes: 100),
                                                      bytes: 100, preset: .balanced, variant: .mrc),
                                 runnerUp: FileVersion(url: try file(root, "r.pdf", bytes: 250),
                                                       bytes: 250, preset: .balanced,
                                                       variant: .plain),
                                 previous: FileVersion(url: try file(root, "p.pdf", bytes: 400),
                                                       bytes: 400, preset: .maximumQuality,
                                                       variant: .plain)),
                     for: id)
        store.setOriginalURL(original, for: id)

        let row = try XCTUnwrap(store.versions(for: id))
        XCTAssertEqual(row.cards.map(\.key),
                       [.shipped, .runnerUp, .previous, .originalReference])
        XCTAssertEqual(row.capsuleTitle, "4 versions")
    }

    /// An empty `searchableByCard` is the honest state of a row whose OCR leg never ran: no mutator
    /// other than `setSearchable` may put a claim in it (spec §6.4 — no subtitle in either
    /// direction on a compress-only row).
    func testSearchableByCardEmptyMeansNoLabels() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        let shipped = try file(root, "out.pdf", bytes: 100)
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: shipped, bytes: 100, preset: .balanced,
                                                      variant: .plain),
                                 runnerUp: nil, previous: nil),
                     for: id)
        XCTAssertTrue(try XCTUnwrap(store.versions(for: id)).searchableByCard.isEmpty)

        store.setSlot(.previous, to: FileVersion(url: try file(root, "p.pdf", bytes: 400),
                                                 bytes: 400, preset: .maximumQuality,
                                                 variant: .plain), for: id)
        store.setShipped(FileVersion(url: shipped, bytes: 80, preset: .smallestSize,
                                     variant: .plain), for: id)
        store.setOriginalURL(try file(root, "in.pdf", bytes: 900), for: id)

        XCTAssertTrue(try XCTUnwrap(store.versions(for: id)).searchableByCard.isEmpty,
                      "only the OCR leg's own results may write a searchability claim")
    }

    /// `setSearchable` records one card's result at a time — the OCR leg appends per file, so each
    /// card's claim is written from that file's own append outcome.
    func testSetSearchablePerCard() throws {
        let (store, _, root) = try makeStore()
        let id = UUID()
        store.record(RowVersions(originalBytes: 900, lastAttemptPreset: .balanced,
                                 shipped: FileVersion(url: try file(root, "out.pdf", bytes: 100),
                                                      bytes: 100, preset: .balanced, variant: .mrc),
                                 runnerUp: nil, previous: nil),
                     for: id)

        store.setSearchable(true, card: .shipped, for: id)
        store.setSearchable(false, card: .originalReference, for: id)
        store.setSearchable(true, card: .previous, for: UUID())

        let row = try XCTUnwrap(store.versions(for: id))
        XCTAssertEqual(row.searchableByCard,
                       [.shipped: true, .originalReference: false],
                       "an unknown row is a no-op and no card is written by implication")
    }
}
