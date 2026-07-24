// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Combine
import XCTest
@testable import Toolbox

/// Drives `CompressViewModel` exactly as the view does — the full batch/preset/estimate/
/// output-folder GUI path (Track C, Task C.2), end to end, with no UI harness involved (the
/// view itself has no logic beyond calling into this model).
@MainActor
final class CompressViewModelTests: XCTestCase {

    /// `compress()` reserves an output name for every job it snapshots, but several MainActor hops
    /// separate that snapshot from the queue launching anything. A file added in that window would
    /// be `.queued`, so the live batch would run it — with no reserved name, allocating from
    /// inside a concurrent job body and racing the very collision the reservation prevents. Both
    /// the "+ Add" button and the drop handler call `add` unconditionally, so the window is
    /// reachable by an ordinary user dropping a file just as a batch starts.
    func testAddIsIgnoredWhileABatchIsRunning() async throws {
        let model = CompressViewModel()
        XCTAssertNil(model.loadError)

        let inputs = [try Fixtures.imagePDF(), try Fixtures.textImagePDF()]
        model.outputFolder = inputs[0].deletingLastPathComponent()
        model.add(inputs)
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }

        model.compress()
        XCTAssertTrue(model.isRunning)

        // The drop that lands a moment too late.
        model.add([try Fixtures.bornDigitalPDF()])
        XCTAssertEqual(model.jobs.count, 2,
                       "a file added mid-batch must not join the running batch unreserved")

        try await waitUntil(timeout: 60) { !model.isRunning }
        // And once the batch is over, adding works normally again.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 3 }
    }

    func testThreeFileSyntheticBatchCompressesEndToEnd() async throws {
        let model = CompressViewModel()
        XCTAssertNil(model.loadError, "Ghostscript should resolve from the test host bundle")

        // Three distinct basenames: a shared output folder collision-avoidance race between
        // same-named concurrent jobs is a separate, pre-existing FileNaming concern (reported
        // separately) — this test proves the batch/estimate/preset/output-folder path C.2 owns.
        // (bilevelPDF() is deliberately avoided here too — compressing it through the real
        // engine at .balanced fails OutputValidator's blank-page check, a second separate
        // pre-existing issue in the shared CompressEngine/OutputValidator/Fixtures path,
        // reproduced standalone and reported rather than fixed here.)
        let inputs = [try Fixtures.imagePDF(), try Fixtures.textImagePDF(), try Fixtures.bornDigitalPDF()]
        let outputFolder = inputs[0].deletingLastPathComponent()
        model.outputFolder = outputFolder

        model.add(inputs)
        try await waitUntil(timeout: 5) { model.jobs.count == 3 }

        // Every queued job should pick up a (possibly fallback) estimate promptly — the
        // estimator is time-boxed to 500 ms, so this should settle well inside 5 s for 3 files.
        try await waitUntil(timeout: 5) {
            model.jobs.allSatisfy { $0.estimate != nil }
        }
        for job in model.jobs {
            XCTAssertNotNil(job.estimate)
            XCTAssertGreaterThan(job.estimate!.predictedBytes, 0)
        }

        XCTAssertTrue(model.canCompress)
        model.compress()
        XCTAssertTrue(model.isRunning)

        try await waitUntil(timeout: 30) {
            model.jobs.allSatisfy { if case .queued = $0.state { return false }
                                     if case .analysing = $0.state { return false }
                                     if case .running = $0.state { return false }
                                     return true }
        }
        try await waitUntil(timeout: 5) { !model.isRunning }

        // Every job reached a terminal, real (queue-driven) outcome — not a leftover estimate.
        for job in model.jobs {
            switch job.state {
            case .done(.compressed(let before, let after)):
                XCTAssertGreaterThan(before, 0)
                XCTAssertGreaterThan(after, 0)
                XCTAssertLessThan(after, before)
            case .done(.noGain):
                break   // the tiny born-digital fixture may legitimately not shrink
            case .failed(let message):
                XCTFail("job for \(job.url.lastPathComponent) failed: \(message)")
            default:
                XCTFail("expected a terminal state, got \(job.state)")
            }
        }

        // Output landed in the chosen folder, one file per input, named "-compressed".
        for input in inputs {
            let expected = outputFolder.appendingPathComponent(
                "\(input.deletingPathExtension().lastPathComponent)-compressed.pdf")
            let job = try XCTUnwrap(model.jobs.first { $0.url == input })
            if case .done(.compressed) = job.state {
                XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                              "expected compressed output at \(expected.path)")
            }
        }
    }

    func testChangingPresetReestimatesQueuedJobs() async throws {
        let model = CompressViewModel()
        let input = try Fixtures.imagePDF()
        model.add([input])

        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }
        let balancedEstimate = try XCTUnwrap(model.jobs.first?.estimate)

        model.preset = .smallestSize
        // The preset change invalidates the old estimate; wait for a fresh one under the
        // new preset (the model briefly clears to .analysing then repopulates `estimate`).
        try await waitUntil(timeout: 5) {
            guard let job = model.jobs.first else { return false }
            guard let estimate = job.estimate else { return false }
            return estimate.predictedBytes != balancedEstimate.predictedBytes || estimate.isFallback
        }
    }

    // MARK: runner-up switch + lifecycle (Task 18)

    /// A `.compressedHeavy` outcome surfaces both versions through `heavyVersions(for:)`, with the
    /// heavy version shipped by default (R7/R8).
    func testCompressedHeavyOutcomePublishesHeavyVersions() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }

        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.heavyVersions(for: job))
        XCTAssertTrue(versions.shippedIsHeavy)
        XCTAssertEqual(versions.heavyBytes, HeavyEnv.heavyBytes)
        XCTAssertEqual(versions.normalBytes, HeavyEnv.normalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: versions.shippedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: versions.runnerUpURL.path))
    }

    /// The switch swaps the files in place and flips `shippedIsHeavy`; a second switch restores the
    /// original state. The byte counts stay intrinsic to each version (R10).
    func testSwitchTogglesInstantlyAndReversibly() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        let shippedURL = try XCTUnwrap(job.resultURL)
        // The shipped file starts as the heavy version (our stub wrote `heavyBytes` there).
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)

        model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        var versions = try XCTUnwrap(model.heavyVersions(for: job))
        XCTAssertFalse(versions.shippedIsHeavy, "after a switch the row ships the normal version")
        XCTAssertEqual(versions.heavyBytes, HeavyEnv.heavyBytes, "byte counts are intrinsic")
        XCTAssertEqual(versions.normalBytes, HeavyEnv.normalBytes)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.normalBytes,
                       "the shipped file now holds the normal version's content")

        model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.heavyVersions(for: job))
        XCTAssertTrue(versions.shippedIsHeavy, "switching again restores the heavy version")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)
    }

    /// `displayedBytes` drives the row's size badge/percent (R10); it must track whichever version
    /// is actually shipped, not always the heavy one.
    func testDisplayedBytesTracksShippedVersion() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        var versions = try XCTUnwrap(model.heavyVersions(for: job))
        XCTAssertEqual(versions.displayedBytes, HeavyEnv.heavyBytes)

        model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.heavyVersions(for: job))
        XCTAssertEqual(versions.displayedBytes, HeavyEnv.normalBytes,
                       "after switching to normal, the badge must show the normal version's bytes")

        model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.heavyVersions(for: job))
        XCTAssertEqual(versions.displayedBytes, HeavyEnv.heavyBytes,
                       "switching back must show the heavy version's bytes again")
    }

    /// When the runner-up file has vanished, the switch honestly re-runs the job (the row shows a
    /// running state) and, on completion, lands on the originally requested version (R10 tail).
    func testSwitchWithMissingRunnerUpRerunsJob() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        // The runner-up leaves the cache; the next switch cannot swap and must re-run.
        try FileManager.default.removeItem(at: runnerUpURL)

        // Freeze the re-run mid-flight so the running state is observable, then release it.
        let gate = Gate()
        env.stub.gate = gate
        let callsBefore = env.stub.callCount

        model.switchVersion(for: job)
        // Wait until the re-run has genuinely entered the engine (callCount bumped), then the row
        // must be in its running state and flagged as re-running.
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        XCTAssertTrue(model.isSwitchRerunning.contains(job.id))
        if case .running = try XCTUnwrap(model.jobs.first).state {} else {
            XCTFail("the re-running row must show a running state")
        }

        await gate.open()
        try await waitUntil(timeout: 5) { !model.isSwitchRerunning.contains(job.id) }

        let settled = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.heavyVersions(for: settled))
        XCTAssertFalse(versions.shippedIsHeavy, "the re-run lands on the requested (normal) version")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runnerUpURL.path),
                      "the re-run regenerated the runner-up")
        // With the refuse-overwrite stub, a switch that silently no-ops (R10's original bug) would
        // have thrown into the outer catch and left `shipped` holding its stale pre-rerun bytes —
        // assert the winning content genuinely landed, not just the bookkeeping flags.
        let shippedURL = try XCTUnwrap(settled.resultURL)
        let shippedData = try Data(contentsOf: shippedURL)
        let runnerUpData = try Data(contentsOf: runnerUpURL)
        XCTAssertEqual(shippedData, Data(repeating: 0x4E, count: HeavyEnv.normalBytes),
                       "the shipped file must hold the regenerated normal version's bytes")
        XCTAssertEqual(runnerUpData, Data(repeating: 0x48, count: HeavyEnv.heavyBytes),
                       "the runner-up slot must hold the regenerated heavy version's bytes")
    }

    /// If the runner-up vanished, the switch re-runs the job, but the *final* swap back into the
    /// switched state can still fail (store contract: a throw means `shipped` is unchanged). That
    /// must not be recorded as a switch — the row must stay canonical (heavy still shipped).
    func testSwitchFailingAfterRerunLeavesStateCanonical() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        // The runner-up leaves the cache; the next switch cannot swap and must re-run.
        try FileManager.default.removeItem(at: runnerUpURL)

        // Freeze the re-run after it has rewritten both files, so the runner-up can be deleted
        // again from under it — the deterministic lever that makes the post-regeneration switch's
        // promote move fail (no file to move), the same failure mode `RunnerUpStoreTests`
        // (`testSwitchRestoresOnFailure`) exercises directly against the store.
        let gate = Gate()
        env.stub.gate = gate
        let callsBefore = env.stub.callCount

        model.switchVersion(for: job)
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        // The stub has written both files and is now suspended on the gate — delete the runner-up
        // it just wrote before releasing it, so the switch that follows finds nothing to promote.
        try FileManager.default.removeItem(at: runnerUpURL)
        await gate.open()

        try await waitUntil(timeout: 5) { !model.isSwitchRerunning.contains(job.id) }

        let settled = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.heavyVersions(for: settled))
        XCTAssertTrue(versions.shippedIsHeavy,
                      "the failed post-regeneration switch must leave the row canonical (heavy shipped)")
    }

    /// Removing a row discards its cached runner-up (R15).
    func testRemoveRowDiscardsRunnerUp() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runnerUpURL.path))

        model.remove(job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runnerUpURL.path),
                       "remove must discard the runner-up")
    }

    /// Clearing finished rows discards every runner-up they held (R15).
    func testClearFinishedDiscardsRunnerUps() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let runnerUpURL = try XCTUnwrap(env.doneHeavyJob(model)?.alternateURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runnerUpURL.path))

        model.clearFinished()
        try await waitUntil(timeout: 5) { model.jobs.isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runnerUpURL.path),
                       "clearFinished must discard runner-ups")
    }

    /// Cancelling the batch reclaims a runner-up that a job wrote before the cancel landed (R15).
    func testCancelDiscardsRunnerUpReservations() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }

        // Hold the job open after it has written both files, so cancel meets a real reservation.
        let gate = Gate()
        env.stub.gate = gate
        model.compress()

        // Wait until the runner-up file exists on disk (the stub writes it before suspending).
        let root = env.storeRoot
        try await waitUntil(timeout: 5) {
            (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .contains { $0.lastPathComponent.contains("runner-up") } ?? false
        }

        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let leftovers = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.contains("runner-up") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "cancel must discard the batch's runner-up reservations")
    }

    // MARK: helpers

    private func fileSize(_ url: URL) throws -> Int {
        // `FileManager` (not `URL.resourceValues`, which caches the size on the URL object across
        // the in-place swap) so each read reflects the file's current content.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? Int)
    }

    /// A view model wired to a stub engine that emits `.compressedHeavy` and writes both versions,
    /// plus a temp-rooted store and output folder — the shared fixture for the switch/lifecycle tests.
    @MainActor
    private struct HeavyEnv {
        static let heavyBytes = 1200
        static let normalBytes = 3400
        let model: CompressViewModel
        let stub: StubEngine
        let input: URL
        let storeRoot: URL

        init() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mrc-track-b-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            storeRoot = tmp.appendingPathComponent("cache", isDirectory: true)
            let outputFolder = tmp.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

            input = try Fixtures.imagePDF()
            stub = StubEngine(outcome: .compressedHeavy(before: 9000,
                                                        after: HeavyEnv.heavyBytes,
                                                        runnerUpBytes: HeavyEnv.normalBytes),
                              shippedBytes: HeavyEnv.heavyBytes,
                              runnerUpBytes: HeavyEnv.normalBytes)
            model = CompressViewModel(engine: stub, store: RunnerUpStore(rootOverride: storeRoot))
            model.outputFolder = outputFolder
        }

        /// The single job once it has reached `.done(.compressedHeavy)`.
        func doneHeavyJob(_ model: CompressViewModel) -> ToolJob? {
            model.jobs.first { if case .done(.compressedHeavy) = $0.state { return true }; return false }
        }
    }

    /// Stub `Compressing`: writes the shipped (and, when given, the runner-up) file, optionally
    /// suspends on a `Gate`, then returns a fixed outcome. Never touches the real MRC pipeline.
    private final class StubEngine: Compressing, @unchecked Sendable {
        let outcome: JobOutcome
        let shippedBytes: Int
        let runnerUpBytes: Int
        private(set) var callCount = 0
        var gate: Gate?

        init(outcome: JobOutcome, shippedBytes: Int, runnerUpBytes: Int) {
            self.outcome = outcome
            self.shippedBytes = shippedBytes
            self.runnerUpBytes = runnerUpBytes
        }

        func compress(_ input: URL, preset: CompressPreset, to output: URL,
                      alternateOutput: URL?, mrcReport: ((MRCDocumentReport) -> Void)?,
                      progress: @escaping (Double) -> Void) async throws -> JobOutcome {
            callCount += 1
            let fm = FileManager.default
            // Mirror the production engine's never-overwrite delivery contract (it `moveItem`s the
            // winner into place, which throws on an existing destination) — a stub that overwrites
            // via `Data.write` would mask a caller that targets an already-occupied destination.
            guard !fm.fileExists(atPath: output.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try Data(repeating: 0x48, count: shippedBytes).write(to: output)
            if let alternateOutput {
                guard !fm.fileExists(atPath: alternateOutput.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try Data(repeating: 0x4E, count: runnerUpBytes).write(to: alternateOutput)
            }
            if let gate { await gate.wait() }
            return outcome
        }
    }

    /// A one-shot latch: `wait()` suspends until `open()` is called (or returns at once if already open).
    private actor Gate {
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct TimedOut: Error, CustomStringConvertible {
        let seconds: TimeInterval
        var description: String { "condition not met within \(seconds)s" }
    }

    /// Polls `condition` until true or `timeout` elapses — a genuine timeout is a **test
    /// failure** (thrown, not skipped): this guards real async completion, not an
    /// environment precondition.
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw TimedOut(seconds: timeout)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
