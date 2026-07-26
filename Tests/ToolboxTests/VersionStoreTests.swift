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

    /// R15's capsule vocabulary: today's dynamic family survives while only the runner-up is
    /// parked, and the title becomes "Versions" once a previous version exists.
    func testCapsuleTitleKeepsTodaysFamilyUntilAPreviousVersionExists() throws {
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
        XCTAssertEqual(store.versions(for: id)?.capsuleTitle, "Heavy compression")

        store.swapShipped(with: .runnerUp, for: id)
        XCTAssertEqual(store.versions(for: id)?.capsuleTitle, "Normal compression")

        store.setSlot(.previous, to: FileVersion(url: try file(root, "p.pdf", bytes: 5), bytes: 5,
                                                 preset: .maximumQuality, variant: .plain), for: id)
        XCTAssertEqual(store.versions(for: id)?.capsuleTitle, "Versions")
        XCTAssertEqual(store.versions(for: id)?.count, 3)
    }
}
