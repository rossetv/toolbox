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

    /// A switch whose shipped file has gone (deleted in Finder — the app has no file watcher) must
    /// throw with the runner-up untouched. Promoting it into the vacant path would leave the cache
    /// slot empty while the row still claims two versions, which is how the caller ends up shipping
    /// one version under the other's label and byte count.
    func testSwitchWithAbsentShippedThrowsAndLeavesTheRunnerUpInPlace() throws {
        let root = try tempRoot()
        let store = RunnerUpStore(rootOverride: root)

        let shipped = root.appendingPathComponent("shipped.pdf")   // never written
        let runnerUp = root.appendingPathComponent("runner-up.pdf")
        try Data("runner-up-content".utf8).write(to: runnerUp)

        XCTAssertThrowsError(try store.switchVersions(shipped: shipped, runnerUp: runnerUp))

        XCTAssertFalse(FileManager.default.fileExists(atPath: shipped.path),
                       "a failed switch must not conjure the deleted file back")
        XCTAssertEqual(try Data(contentsOf: runnerUp), Data("runner-up-content".utf8),
                       "the runner-up must survive a switch that did not happen")
        let leftoverSwapFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".toolbox-swap-") }
        XCTAssertTrue(leftoverSwapFiles.isEmpty)
    }

    /// A promote that fails AFTER the shipped file was parked must restore it — via the
    /// documented `moveItem` path, since the shipped slot is empty at that moment. An absent
    /// runner-up forces exactly that sequence deterministically.
    func testFailedPromoteRestoresTheShippedFile() throws {
        let root = try tempRoot()
        let store = RunnerUpStore(rootOverride: root)

        let shipped = root.appendingPathComponent("shipped.pdf")
        try Data("shipped-content".utf8).write(to: shipped)
        let runnerUp = root.appendingPathComponent("runner-up.pdf")   // never written

        XCTAssertThrowsError(try store.switchVersions(shipped: shipped, runnerUp: runnerUp)) { error in
            XCTAssertFalse(error is RunnerUpStore.SwitchError,
                           "the restore succeeded, so the failure must surface as the promote's own error")
        }
        XCTAssertEqual(try Data(contentsOf: shipped), Data("shipped-content".utf8),
                       "a failed promote must put the user's shipped file back untouched")
        let leftoverSwapFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".toolbox-swap-") }
        XCTAssertTrue(leftoverSwapFiles.isEmpty, "the park file must not be left behind")
    }

    /// If the final move (parked -> runner-up slot) fails, the switch has already succeeded from
    /// the user's perspective (shipped holds the new content) — the function must not throw. The
    /// reviewer's suggested lever (pre-existing non-empty directory at the runner-up path) cannot
    /// isolate this: promoting the runner-up always fully vacates that path first, so nothing is
    /// left to block the demote. Instead this uses a macOS ACL that denies adding entries to the
    /// runner-up's directory while still permitting removal of existing ones — asymmetric in
    /// exactly the way needed: the promote (which removes the runner-up entry) succeeds, and only
    /// the demote (which creates a new entry there) fails.
    func testDemoteFailureDoesNotThrowAndShippedHoldsNewContent() throws {
        let root = try tempRoot()
        let store = RunnerUpStore(rootOverride: root)

        let runDir = root.appendingPathComponent("rundir", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        let shipped = root.appendingPathComponent("shipped.pdf")
        let runnerUp = runDir.appendingPathComponent("runner-up.pdf")
        try Data("shipped-content".utf8).write(to: shipped)
        try Data("runner-up-content".utf8).write(to: runnerUp)

        let acl = Process()
        acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["+a", "everyone deny add_file,add_subdirectory", runDir.path]
        try acl.run()
        acl.waitUntilExit()
        XCTAssertEqual(acl.terminationStatus, 0, "setting up the ACL must succeed for the test to be meaningful")

        XCTAssertNoThrow(try store.switchVersions(shipped: shipped, runnerUp: runnerUp))

        XCTAssertEqual(try Data(contentsOf: shipped), Data("runner-up-content".utf8))

        let leftoverSwapFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".toolbox-swap-") }
        XCTAssertTrue(leftoverSwapFiles.isEmpty, "the parked file must be discarded, not stranded")
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

    /// The quit-time hook (Task 19): a static that empties the cache directory without needing
    /// an instance, exercised here against a temp root override.
    func testRemoveAllOnDiskEmptiesCacheDirectory() throws {
        let root = try tempRoot()

        try Data("a".utf8).write(to: root.appendingPathComponent("one.pdf"))
        try Data("b".utf8).write(to: root.appendingPathComponent(".swap-leftover.pdf"))

        RunnerUpStore.removeAllOnDisk(root: root)

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

    // MARK: R12 commit protocol (recompress)

    /// The commit: the previously shipped file ends up in the cache slot `parking` names and the
    /// fresh result takes its place. Every move lands, and neither the temp path nor the
    /// beside-the-shipped-file dot-temp is left behind.
    func testPromoteParksTheShippedFileAndLandsTheFreshOne() async throws {
        let root = try tempRoot()
        let delivery = root.appendingPathComponent("delivery", isDirectory: true)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let store = RunnerUpStore(rootOverride: root)

        // The shipped file lives where the USER's output lives, not in the cache root — the whole
        // point of the three-step shape is that the two are different places.
        let shipped = delivery.appendingPathComponent("shipped.pdf")
        let fresh = delivery.appendingPathComponent(".toolbox-recompress.pdf")
        let parked = root.appendingPathComponent("shipped-previous.pdf")
        try Data("old-version".utf8).write(to: shipped)
        try Data("new-version".utf8).write(to: fresh)

        try await store.promote(fresh: fresh, to: shipped, parking: parked)

        XCTAssertEqual(try Data(contentsOf: shipped), Data("new-version".utf8))
        XCTAssertEqual(try Data(contentsOf: parked), Data("old-version".utf8),
                       "the version the user had must reach the cache slot it was reserved, not "
                     + "merely survive somewhere")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        // The intermediate dot-temp is a transient, not a resting place: nothing named
        // `.toolbox-*` may survive beside the delivered file.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: delivery.path)
            .filter { $0.hasPrefix(".toolbox-") }
        XCTAssertTrue(leftovers.isEmpty, "the dot-temp must not outlive the commit: \(leftovers)")
    }

    /// The third step is best-effort by design: if the parked version cannot reach its cache slot
    /// the commit still SUCCEEDS (the user has their new file) and the old version is discarded
    /// rather than stranded under a hidden dot-name nothing will ever look for.
    func testPromoteSucceedsAndDiscardsWhenTheParkSlotIsUnreachable() async throws {
        let root = try tempRoot()
        let delivery = root.appendingPathComponent("delivery", isDirectory: true)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let store = RunnerUpStore(rootOverride: root)

        let shipped = delivery.appendingPathComponent("shipped.pdf")
        let fresh = delivery.appendingPathComponent(".toolbox-recompress.pdf")
        // A park path inside a directory that does not exist: the move to the cache slot cannot
        // succeed, deterministically.
        let parked = root.appendingPathComponent("absent-dir/shipped-previous.pdf")
        try Data("old-version".utf8).write(to: shipped)
        try Data("new-version".utf8).write(to: fresh)

        // The commit must not throw here — an unreachable park slot is a best-effort third step,
        // so a throw out of this line is itself the failure the test is looking for.
        try await store.promote(fresh: fresh, to: shipped, parking: parked)

        XCTAssertEqual(try Data(contentsOf: shipped), Data("new-version".utf8),
                       "the promotion is what the user pressed the button for; it stands")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: delivery.path)
            .filter { $0.hasPrefix(".toolbox-") }
        XCTAssertTrue(leftovers.isEmpty, "a park that cannot land is discarded, never stranded")
    }

    /// R12's load-bearing guarantee: the old version survives any failure. An absent `fresh` makes
    /// the promote move fail deterministically, after the shipped file has already been parked.
    func testPromoteFailureRestoresTheShippedFile() async throws {
        let root = try tempRoot()
        let delivery = root.appendingPathComponent("delivery", isDirectory: true)
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true)
        let store = RunnerUpStore(rootOverride: root)

        let shipped = delivery.appendingPathComponent("shipped.pdf")
        let fresh = delivery.appendingPathComponent(".toolbox-recompress.pdf")   // never written
        let parked = root.appendingPathComponent("shipped-previous.pdf")
        try Data("old-version".utf8).write(to: shipped)

        do {
            try await store.promote(fresh: fresh, to: shipped, parking: parked)
            XCTFail("an absent fresh file must fail the promotion")
        } catch {
            XCTAssertFalse(error is RunnerUpStore.SwitchError,
                           "the restore succeeded, so the promote's own error must surface")
        }
        XCTAssertEqual(try Data(contentsOf: shipped), Data("old-version".utf8),
                       "a failed commit must put the user's file back untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parked.path),
                       "the park slot must not keep a copy after the restore")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: delivery.path)
            .filter { $0.hasPrefix(".toolbox-") }
        XCTAssertTrue(leftovers.isEmpty,
                      "the dot-temp must be emptied by the restore: \(leftovers)")
    }

    /// Parked previous versions and runner-ups share the cache root, so they must not collide: the
    /// suffix is what keeps a row's two parked files apart under the same serial allocator.
    func testReserveURLHonoursTheRequestedSuffix() throws {
        let root = try tempRoot()
        let store = RunnerUpStore(rootOverride: root)
        let input = root.appendingPathComponent("scan.pdf")

        var reserved = Set<String>()
        let runnerUp = store.reserveURL(for: input, reserving: &reserved)
        let previous = store.reserveURL(for: input, suffix: "previous", reserving: &reserved)

        XCTAssertEqual(runnerUp.lastPathComponent, "scan-runner-up.pdf")
        XCTAssertEqual(previous.lastPathComponent, "scan-previous.pdf")
    }
}
