// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

/// `RunnerUpStore` owns the app's one exception to "no persisted state" (spec R15): a cache
/// directory holding losing compression versions, swept at launch and on row/batch/quit
/// lifecycle events (Tasks 18-19). Exercised here against a temp `rootOverride` so the suite
/// never touches the real caches directory.
@MainActor
final class RunnerUpStoreTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-up-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Same basename from two different source folders must not collide in the shared cache
    /// folder — the same serial-reservation guarantee `FileNaming` gives every batch output (C4).
    func testReserveAllocatesDistinctNamesForSameBasename() throws {
        let root = try tempRoot()
        let store = RunnerUpStore(rootOverride: root)

        let folderA = root.appendingPathComponent("A", isDirectory: true)
        let folderB = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        let inputA = folderA.appendingPathComponent("scan.pdf")
        let inputB = folderB.appendingPathComponent("scan.pdf")

        var reserved = Set<String>()
        let urlA = store.reserveURL(for: inputA, reserving: &reserved)
        let urlB = store.reserveURL(for: inputB, reserving: &reserved)

        XCTAssertNotEqual(urlA, urlB)
        XCTAssertEqual(urlA.deletingLastPathComponent().path, urlB.deletingLastPathComponent().path)
        XCTAssertEqual(urlA.lastPathComponent, "scan-runner-up.pdf")
        XCTAssertEqual(urlB.lastPathComponent, "scan-runner-up-1.pdf")
    }

    func testSwitchExchangesContents() throws {
        let root = try tempRoot()
        let store = RunnerUpStore(rootOverride: root)

        let shipped = root.appendingPathComponent("shipped.pdf")
        let runnerUp = root.appendingPathComponent("runner-up.pdf")
        try Data("shipped-content".utf8).write(to: shipped)
        try Data("runner-up-content".utf8).write(to: runnerUp)

        try store.switchVersions(shipped: shipped, runnerUp: runnerUp)

        XCTAssertEqual(try Data(contentsOf: shipped), Data("runner-up-content".utf8))
        XCTAssertEqual(try Data(contentsOf: runnerUp), Data("shipped-content".utf8))
    }

    /// If promoting the runner-up fails, the parked shipped file must be restored — the user's
    /// output must survive every failure path.
    func testSwitchRestoresOnFailure() throws {
        let root = try tempRoot()
        let store = RunnerUpStore(rootOverride: root)

        let shipped = root.appendingPathComponent("shipped.pdf")
        let runnerUp = root.appendingPathComponent("runner-up.pdf")
        try Data("shipped-content".utf8).write(to: shipped)
        // No runner-up file written — the promote move must fail.

        XCTAssertThrowsError(try store.switchVersions(shipped: shipped, runnerUp: runnerUp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shipped.path))
        XCTAssertEqual(try Data(contentsOf: shipped), Data("shipped-content".utf8))
    }

    func testSweepStaleEmptiesDirectory() throws {
        let root = try tempRoot()
        let store = RunnerUpStore(rootOverride: root)

        try Data("a".utf8).write(to: root.appendingPathComponent("one.pdf"))
        try Data("b".utf8).write(to: root.appendingPathComponent(".swap-leftover.pdf"))

        store.sweepStale()

        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testDiscardRemovesFile() throws {
        let root = try tempRoot()
        let store = RunnerUpStore(rootOverride: root)

        let file = root.appendingPathComponent("gone.pdf")
        try Data("x".utf8).write(to: file)

        store.discard(file)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
