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

    /// A `.compressedHeavy` outcome surfaces both versions through `versions(for:)`, with the
    /// heavy version shipped by default (R7/R8).
    func testCompressedHeavyOutcomePublishesHeavyVersions() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }

        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertTrue(versions.shipped?.variant == .mrc)
        XCTAssertEqual(try XCTUnwrap(versions.cards.first(where: { $0.version.variant == .mrc })?.version.bytes),
                       HeavyEnv.heavyBytes)
        XCTAssertEqual(try XCTUnwrap(versions.cards.first(where: { $0.version.variant != .mrc })?.version.bytes),
                       HeavyEnv.normalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(versions.shipped?.url).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(versions.runnerUp?.url).path))
        XCTAssertFalse(versions.runnerUp?.variant == .original,
                       "a gs runner-up smaller than the input is not the original")
    }

    /// When the engine parked the ORIGINAL instead of a gs runner-up (gs bloated, so
    /// `runnerUpBytes == before` — R6/R7 field fix), `versions(for:)` must mark it so the
    /// popover labels that card "Original" rather than "Normal".
    func testRunnerUpMarkedAsOriginalWhenBytesEqualInputSize() async throws {
        let env = try HeavyEnv(before: HeavyEnv.normalBytes)
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }

        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertTrue(versions.runnerUp?.variant == .original)
    }

    /// A report the engine hands back via the `mrcReport` closure is retained on the job result
    /// (spec §5/§6's debugging record), not discarded.
    func testCompressedHeavyRetainsMRCReportOnJob() async throws {
        let env = try HeavyEnv()
        let expectedReport = MRCDocumentReport(verdicts: [.mrcEncoded(MRCPageFeatures(
            inkCoverage: 0.4, meanComponentSize: 12, componentCount: 30, colourCoverage: 0.1,
            moderateChromaCoverage: 0.1
        ))])
        env.stub.reportToDeliver = expectedReport
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }

        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        XCTAssertEqual(job.mrcReport, expectedReport)
    }

    /// A second tap before the first switch lands must be a no-op, not a second concurrent swap on
    /// the same paths. `useVersion` sets its re-entrancy guard (`isSwitchRerunning`) synchronously,
    /// before `store.switchVersions`'s first suspension point, so the two MainActor tasks below can
    /// race for real without needing an artificial delay: the first runs its synchronous prefix to
    /// completion (setting the guard) before yielding, so the second observes the guard already set.
    func testSecondUseVersionTapWhileFirstIsInFlightIsANoOp() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let shippedURL = try XCTUnwrap(job.resultURL)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)

        async let first: Void = model.switchVersion(for: job)
        async let second: Void = model.switchVersion(for: job)
        _ = await (first, second)

        let switchedJob = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.versions(for: switchedJob))
        XCTAssertFalse(versions.shipped?.variant == .mrc,
                       "two concurrent taps must still land on exactly one switch, not cancel back out")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.normalBytes,
                       "the shipped file must hold exactly one version's content, not a mangled swap")
        if case .failed = switchedJob.state {
            XCTFail("a raced second tap must never surface a false failure")
        }
    }

    /// The switch swaps the files in place and flips which version is shipped; a second switch
    /// restores the original state. The byte counts stay intrinsic to each version (R10).
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

        await model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        var versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertFalse(versions.shipped?.variant == .mrc, "after a switch the row ships the normal version")
        XCTAssertEqual(try XCTUnwrap(versions.cards.first(where: { $0.version.variant == .mrc })?.version.bytes),
                       HeavyEnv.heavyBytes, "byte counts are intrinsic")
        XCTAssertEqual(try XCTUnwrap(versions.cards.first(where: { $0.version.variant != .mrc })?.version.bytes),
                       HeavyEnv.normalBytes)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.normalBytes,
                       "the shipped file now holds the normal version's content")

        await model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertTrue(versions.shipped?.variant == .mrc, "switching again restores the heavy version")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)
    }

    /// A plain instant swap (the parked file still exists — no engine re-run) must render the row
    /// as finished throughout, never as a running job (R4/R7): `isSwitchRerunning` is only a
    /// re-entrancy guard, and `publishJobs()` must not treat guard membership alone as "busy" —
    /// only a genuine `rerunForSwitch` re-run (which populates `rerunProgress`) may do that.
    /// There is no seam to gate `performSwap`'s GCD hop (`RunnerUpStoreTests` doesn't gate it
    /// either), so this polls on a concurrent task instead of pausing mid-flight; `Task.yield()`
    /// gives the scheduler real opportunities to interleave and observe a corrupted frame if one
    /// existed.
    func testPlainSwitchNeverExposesARunningRowOrDropsAllFinished() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let job = try XCTUnwrap(env.doneHeavyJob(model))

        let watchdog = Task { @MainActor () -> Bool in
            var corrupted = false
            while !Task.isCancelled {
                if env.doneHeavyJob(model) == nil { corrupted = true }
                if !model.allFinished { corrupted = true }
                await Task.yield()
            }
            return corrupted
        }

        await model.switchVersion(for: job)

        watchdog.cancel()
        let corrupted = try await watchdog.value
        XCTAssertFalse(corrupted,
                       "a plain swap must keep the row .done/.doneHeavy and allFinished true throughout")
    }

    /// `capsuleTitle` drives the row's capsule label; it must flip with the shipped version and use
    /// the popover's own vocabulary for the parked version — "Normal compression" when the runner-up
    /// is a real gs output, matching the label `VersionsPopover.label(_:slot:)` gives the parked
    /// card, "Normal".
    func testCapsuleTitleFlipsOnSwitch() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        var versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(versions.capsuleTitle, "Heavy compression")

        await model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(versions.capsuleTitle, "Normal compression",
                       "the parked version is a real gs output, not the untouched input")

        await model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(versions.capsuleTitle, "Heavy compression",
                       "switching back restores the heavy label")
    }

    /// When the runner-up is the untouched original (R6/R7 field fix), switching to it must label
    /// the capsule "Original" — matching the label `VersionsPopover.label(_:slot:)` gives that card
    /// — not "Normal compression".
    func testCapsuleTitleReadsOriginalWhenRunnerUpIsInput() async throws {
        let env = try HeavyEnv(before: HeavyEnv.normalBytes)
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        await model.switchVersion(for: job)
        let switchedJob = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.versions(for: switchedJob))
        XCTAssertFalse(versions.shipped?.variant == .mrc)
        XCTAssertEqual(versions.capsuleTitle, "Original")
    }

    /// `displayedSizes(for:)` feeds the batch success banner's totals; for a `.compressedHeavy` job it
    /// must count the SHIPPED version's bytes, not always the heavy outcome's `after`, so a switch
    /// keeps the banner in sync with the row's own badge (sibling of the 730b67b badge fix).
    func testSavedBytesUsesShippedVersionForHeavyJob() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        var saved = try XCTUnwrap(model.displayedSizes(for: job))
        XCTAssertEqual(saved.before, 9000)
        XCTAssertEqual(saved.after, HeavyEnv.heavyBytes,
                       "the heavy version ships by default, so it must be counted")

        await model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        saved = try XCTUnwrap(model.displayedSizes(for: job))
        XCTAssertEqual(saved.after, HeavyEnv.normalBytes,
                       "after switching to normal, the banner totals must use the normal bytes")
    }

    /// The shipped version's byte count drives the row's size badge/percent (R10); it must track
    /// whichever version is actually shipped, not always the heavy one.
    func testDisplayedBytesTracksShippedVersion() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        var versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(try XCTUnwrap(versions.shipped?.bytes), HeavyEnv.heavyBytes)

        await model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(try XCTUnwrap(versions.shipped?.bytes), HeavyEnv.normalBytes,
                       "after switching to normal, the badge must show the normal version's bytes")

        await model.switchVersion(for: job)
        job = try XCTUnwrap(env.doneHeavyJob(model))
        versions = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(try XCTUnwrap(versions.shipped?.bytes), HeavyEnv.heavyBytes,
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

        await model.switchVersion(for: job)
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
        let versions = try XCTUnwrap(model.versions(for: settled))
        XCTAssertFalse(versions.shipped?.variant == .mrc,
                       "the re-run lands on the requested (normal) version")
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

    /// R9's sixth mutating control: an armed row can still read `.doneHeavy` between `compress()`
    /// starting and phase 2 reaching it, so without the `isRunning` guard a switch here would race
    /// a second engine run against the in-flight run's own commit. Assert `useVersion` is a no-op
    /// for the whole run.
    func testUseVersionIsIgnoredWhileARunIsInFlight() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        // Vanish the runner-up so a permitted switch would fall through to `rerunForSwitch` and
        // hit the engine — the exact second run the guard must prevent.
        try FileManager.default.removeItem(at: runnerUpURL)

        // A second row to occupy a genuinely in-flight run, gated so it stays mid-flight.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount

        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        XCTAssertTrue(model.isRunning)

        await model.useVersion(.runnerUp, for: job)
        XCTAssertEqual(env.stub.callCount, callsBefore + 1,
                       "useVersion must not start a second engine run while a run is in flight")
        XCTAssertFalse(model.isSwitchRerunning.contains(job.id))

        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }
    }

    /// The symmetric guard: `compress()` must refuse while a switch's re-run is in flight, not just
    /// while `isRunning` is true — otherwise phase 2's promote would race the very shipped path an
    /// outstanding switch is still rewriting, and reservations would be handed out for paths that
    /// are transiently absent mid-swap (R9).
    func testCompressIsRefusedWhileASwitchIsInFlight() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(env.doneHeavyJob(model))
        let runnerUpURL = try XCTUnwrap(job.alternateURL)
        // Vanish the runner-up so the switch falls through to `rerunForSwitch` and hits the engine,
        // and freeze that re-run mid-flight so `isSwitchRerunning` stays populated.
        try FileManager.default.removeItem(at: runnerUpURL)
        let gate = Gate()
        env.stub.gate = gate
        let callsBefore = env.stub.callCount

        async let switching: Void = model.switchVersion(for: job)
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        XCTAssertTrue(model.isSwitchRerunning.contains(job.id))
        XCTAssertFalse(model.isRunning, "the switch's re-run, not a compress run, is in flight")

        // An armed/queued row present alongside the in-flight switch.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        XCTAssertFalse(model.canCompress, "the footer button must disable, not silently no-op")

        model.compress()
        XCTAssertFalse(model.isRunning, "compress() must not start a run while a switch is in flight")
        XCTAssertEqual(env.stub.callCount, callsBefore + 1,
                       "the engine must not be invoked by the refused compress() call")

        await gate.open()
        _ = await switching
        try await waitUntil(timeout: 5) { !model.isSwitchRerunning.contains(job.id) }

        // Now that the switch has landed, compress() must work again.
        XCTAssertTrue(model.canCompress)
        let callsAfterSwitch = env.stub.callCount
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }
        try await waitUntil(timeout: 5) { env.stub.callCount > callsAfterSwitch }
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

        await model.switchVersion(for: job)
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        // The stub has written both files and is now suspended on the gate — delete the runner-up
        // it just wrote before releasing it, so the switch that follows finds nothing to promote.
        try FileManager.default.removeItem(at: runnerUpURL)
        await gate.open()

        try await waitUntil(timeout: 5) { !model.isSwitchRerunning.contains(job.id) }

        let settled = try XCTUnwrap(env.doneHeavyJob(model))
        let versions = try XCTUnwrap(model.versions(for: settled))
        XCTAssertTrue(versions.shipped?.variant == .mrc,
                      "the failed post-regeneration switch must leave the row canonical (heavy shipped)")
    }

    /// A second batch at a different preset must not rewrite what an ALREADY-FINISHED row was
    /// compressed under: `ToolQueue` only ever re-runs `.queued` jobs, so a finished row keeps its
    /// own preset, and the R10 re-run must reproduce that output rather than silently replacing the
    /// user's delivered file with a differently-compressed one.
    func testLaterBatchDoesNotRewriteAFinishedRowsPreset() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .smallestSize
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let job1 = try XCTUnwrap(env.doneHeavyJob(model))

        // Arm the finished row at .balanced and let the engine come back no-gain, so the row is
        // recorded FUTILE at .balanced (R6) without touching the shipped version at all — `rowPreset`
        // reads `shipped?.preset` first (R14), so it stays .smallestSize throughout.
        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .balanced
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertEqual(model.versions(for: job1)?.rowPreset, .smallestSize)
        env.stub.script = nil

        // A second file joins the list alongside the finished row, and the batch runs at .balanced
        // too — the SAME preset the row is now futile at. Being futile, the row does not arm (R6),
        // so it takes no part in this run's engine calls and `ToolQueue` never touches it: this is
        // the adversarial batch-time case — a later batch running at a preset that differs from the
        // finished row's own, while that row sits out the run untouched. Recording a pending preset
        // for it anyway (the §9.5 defect) would let the row's finished record get silently rewritten
        // to .balanced on the next ingest, even though nothing recompressed it.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.compress()
        try await waitUntil(timeout: 10) { !model.isRunning }

        XCTAssertEqual(model.versions(for: job1)?.rowPreset, .smallestSize,
                       "a later batch that didn't recompress this row must not rewrite its preset")

        // The first row's runner-up vanishes, so switching it honestly re-runs the job — which
        // must go through the engine at the preset that row was compressed at.
        let job = try XCTUnwrap(model.jobs.first { $0.url == env.input })
        try FileManager.default.removeItem(at: try XCTUnwrap(job.alternateURL))
        let callsBefore = env.stub.callCount

        await model.switchVersion(for: job)
        try await waitUntil(timeout: 5) {
            env.stub.callCount > callsBefore && !model.isSwitchRerunning.contains(job.id)
        }

        XCTAssertEqual(env.stub.presets.last, .smallestSize,
                       "the re-run must reproduce the row's own output, not the current preset")
    }

    /// The delivered file can disappear behind the app's back (deleted or moved in Finder — there
    /// is no file watcher). The switch must then fail loudly: re-running would regenerate the pair
    /// around a stale runner-up, and two further switches would hand the user the HEAVY file under
    /// the "Normal compression" label with gs's byte count in the row and the batch totals.
    func testSwitchWithADeletedShippedFileFailsLoudlyRatherThanMislabelling() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        var job = try XCTUnwrap(env.doneHeavyJob(model))
        let shippedURL = try XCTUnwrap(job.resultURL)
        await model.switchVersion(for: job)                       // now shipping the normal version
        job = try XCTUnwrap(env.doneHeavyJob(model))
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.normalBytes)

        try FileManager.default.removeItem(at: shippedURL)  // the user deletes it in Finder
        let callsBefore = env.stub.callCount

        await model.switchVersion(for: job)

        XCTAssertEqual(env.stub.callCount, callsBefore,
                       "a row whose delivered file is gone must not be re-run behind the user's back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shippedURL.path),
                       "the deleted file must not be silently re-created")
        let row = try XCTUnwrap(model.jobs.first)
        guard case .failed(let message) = row.state else {
            return XCTFail("expected the row to report the failed switch, got \(row.state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(model.versions(for: row),
                     "the row must stop advertising a version pair it cannot back")
        XCTAssertNil(model.displayedSizes(for: row),
                     "and must stop contributing bytes to the batch totals")
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

    // MARK: arming (R1/R3/R6/R7)

    /// Selecting a different preset with finished rows showing arms them; the row's own preset
    /// leaves it alone (R1).
    func testSelectingADifferentPresetArmsAFinishedRow() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .none,
                       "the row's own preset must not arm it")

        model.preset = .smallestSize
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .armed(.smallestSize))
        XCTAssertEqual(model.armedCount, 1)
    }

    /// R3: re-selecting the row's preset disarms it instantly, leaving no residue.
    func testReselectingTheRowsPresetDisarmsIt() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        model.preset = .smallestSize
        XCTAssertEqual(model.armedCount, 1)
        model.preset = .balanced
        XCTAssertEqual(model.armedCount, 0)
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)), .none)
    }

    /// A `.failed` row never arms — its recourse is re-adding the file, not a re-run (R1).
    func testFailedRowsNeverArm() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.throwOnCall = 1
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        guard case .failed = job.state else { return XCTFail("expected a failed row, got \(job.state)") }
        XCTAssertEqual(model.recompressState(for: job), .none)
        XCTAssertEqual(model.armedCount, 0)
    }

    /// A no-gain row arms at a DIFFERENT preset ("still too big" is exactly its user) but reports
    /// its own preset as futile rather than re-arming a known-futile run (R1/R6).
    func testNoGainRowArmsElsewhereAndIsFutileAtItsOwnPreset() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .futile(.balanced))

        model.preset = .smallestSize
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .armed(.smallestSize), "a no-gain row is the 'still too big' case — it arms")
    }

    /// Nothing arms while a run is in flight — the selector is disabled for the duration (R9), and
    /// the state must agree with the control.
    func testNothingArmsWhileARunIsInFlight() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        let gate = Gate()
        env.stub.gate = gate
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }

        model.preset = .smallestSize
        XCTAssertEqual(model.armedCount, 0)
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }
    }

    // MARK: recompress prediction (R16)

    /// A row whose engine path repeats scales the raw estimate by what the engine actually did —
    /// the calibration that stops an MRC row's recompression being predicted as a 4× growth.
    func testPredictionScalesByTheObservedRatioWhenThePathRepeats() async throws {
        // `.scanColour` at `.smallestSize` is the only pair reachable from this row's `.balanced`
        // shipped preset giving
        // `targetWantsMRC == shippedWasMRC == true` with a non-degenerate ratio: `HeavyEnv` always
        // ships `.compressedHeavy` (`shippedWasMRC` is always true), so the repeating-path case
        // needs a target that is ALSO MRC-eligible — `.scanColour` + a non-Maximum preset — not
        // `.bornDigital`, which is never MRC-eligible and so never repeats the path.
        let env = try HeavyEnv(contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        let analysis = try XCTUnwrap(model.analysis(for: job))
        let balanced = try XCTUnwrap(analysis.estimates[.balanced]?.predictedBytes)
        let smallest = try XCTUnwrap(analysis.estimates[.smallestSize]?.predictedBytes)
        // Associated EXACTLY as the implementation associates it: `Int(_:)` truncates, so a
        // differently-bracketed expression of the same real number can land one byte away.
        let expected = Int((Double(HeavyEnv.heavyBytes) / Double(balanced)) * Double(smallest))

        let predicted = try XCTUnwrap(model.recompressPrediction(for: job, at: .smallestSize))
        XCTAssertEqual(predicted, expected,
                       "a scanColour row shipped MRC and staying MRC-eligible at Smallest Size has "
                       + "a path that repeats, so the observed ratio applies")
    }

    /// A `.scanColour` row that shipped MRC crossing to Maximum quality (never MRC-eligible) must
    /// use the RAW estimate — the ratio was learned on a path that will not run.
    func testPredictionUsesTheRawEstimateWhenTheEnginePathChanges() async throws {
        // A large original, so the "must beat the original" guard cannot mask the calibration rule
        // this test exists to pin.
        let env = try HeavyEnv(before: 50_000_000, contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        let analysis = try XCTUnwrap(model.analysis(for: job))
        let raw = try XCTUnwrap(analysis.estimates[.maximumQuality]?.predictedBytes)

        XCTAssertEqual(model.recompressPrediction(for: job, at: .maximumQuality), raw,
                       "an MRC-shipped row crossing to Maximum quality gets the raw gs estimate")
    }

    /// Any prediction at or above the original renders as "may not shrink", never a confident
    /// number (R16) — the model says so by returning nil.
    func testPredictionIsWithheldWhenItWouldNotBeatTheOriginal() async throws {
        // This row takes the RAW-estimate branch, not the scaled one: the shipped version is MRC
        // (`HeavyEnv` produces `.compressedHeavy`) while `.bornDigital` + `.maximumQuality` gives
        // `targetWantsMRC == false`, so the paths differ and no calibration is applied. The guard
        // then fires deterministically because the raw estimate is derived from the REAL fixture,
        // which is far larger than the 1 kB original the stub reports — so `predicted` cannot be
        // below `row.originalBytes` whatever the estimator predicts.
        let env = try HeavyEnv(before: 1_000, contentType: .bornDigital)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNil(model.recompressPrediction(for: job, at: .maximumQuality))
    }

    /// R10's ARMING half: the missing-original guard fires before a confident number is offered,
    /// not only before the run. A row whose input has been deleted must not display a pill
    /// promising a size the app has no way to produce.
    func testPredictionIsWithheldWhenTheOriginalIsGone() async throws {
        // `.scanColour`, so the POSITIVE control is genuinely confident before the deletion. The
        // shipped version is MRC and `.scanColour` + `.smallestSize` gives `targetWantsMRC == true`,
        // so `targetWantsMRC == shippedWasMRC` and the calibration branch runs: the prediction
        // tracks the shipped 1.2 kB (scaled by raw/baseline), comfortably under the 9 kB original.
        // With `.bornDigital` the paths would differ, the RAW estimate would be used, and that is
        // derived from the multi-megabyte `imagePDF` fixture — the "must beat the original" guard
        // would return nil before the deletion too, and the test would assert nothing.
        let env = try HeavyEnv(contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNotNil(model.recompressPrediction(for: job, at: .smallestSize),
                        "the row predicts confidently while its input is still there")

        try FileManager.default.removeItem(at: env.input)
        XCTAssertNil(model.recompressPrediction(for: job, at: .smallestSize),
                     "no input, no prediction — R10 applies at arming time, not just at run time")
        XCTAssertTrue(model.isOriginalMissing(for: job))
    }

    // MARK: recompress commit protocol (R10–R13)

    /// The happy path: the fresh result takes the row's existing output path, the version it
    /// replaced is parked as the previous version, and every aggregate follows the new one.
    func testRecompressCommitsAndParksThePreviousVersion() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let row = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(row.shipped?.url, shippedURL, "a recompress writes to the row's own output")
        XCTAssertEqual(row.shipped?.bytes, 700)
        XCTAssertEqual(row.shipped?.preset, .smallestSize)
        XCTAssertEqual(try fileSize(shippedURL), 700, "the delivered file holds the new version")
        let previous = try XCTUnwrap(row.previous)
        XCTAssertEqual(previous.bytes, HeavyEnv.heavyBytes)
        XCTAssertEqual(previous.preset, .balanced)
        XCTAssertEqual(try fileSize(previous.url), HeavyEnv.heavyBytes,
                       "the version the user had is parked intact")
        XCTAssertEqual(model.displayedSizes(for: job)?.after, 700)
    }

    /// The shipped file can be deleted outside the app between shipping and the next recompress —
    /// there is nothing to park, but the recompress itself still succeeds, so it must deliver the
    /// fresh result rather than discard it behind a lying "kept your X version" message.
    func testRecompressDeliversTheFreshResultWhenTheShippedFileWasDeletedOutsideTheApp() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)
        try FileManager.default.removeItem(at: shippedURL)  // the user deletes it in Finder

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let row = try XCTUnwrap(model.versions(for: job))
        XCTAssertNil(model.recompressErrors[job.id], "the recompress succeeded — there is no failure to report")
        XCTAssertEqual(row.shipped?.url, shippedURL, "the fresh result lands at the row's own output path")
        XCTAssertEqual(row.shipped?.bytes, 700)
        XCTAssertEqual(row.shipped?.preset, .smallestSize)
        XCTAssertEqual(try fileSize(shippedURL), 700, "the new file is actually delivered on disk")
        XCTAssertNil(row.previous, "there was nothing to park")
    }

    /// R7: when the parked previous version was made at the selected preset, the row offers an
    /// instant switch instead of arming a recompute of a file already in the cache.
    ///
    /// Written here rather than in Task 7 (where it was specified): it cannot be satisfied before
    /// the recompress commit exists, because nothing else ever fills the `previous` slot.
    func testPreviousVersionsPresetOffersAnInstantSwitchRatherThanArming() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        // Recompress at Smallest, parking the Balanced version.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        model.preset = .balanced
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .instantSwitch(.balanced))
        XCTAssertEqual(model.armedCount, 0)
    }

    /// R12: an engine failure keeps the version the user had, on disk and on screen, and says so.
    func testRecompressFailureKeepsThePreviousVersionAndReportsIt() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        env.stub.throwOnCall = env.stub.callCount + 1
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes,
                       "the user's file must be exactly as it was")
        XCTAssertEqual(model.recompressErrors[job.id],
                       "Recompress failed — kept your Balanced version")
        XCTAssertEqual(model.versions(for: job)?.shipped?.preset, .balanced)
        XCTAssertNil(model.versions(for: job)?.previous, "a failed commit parks nothing")
        // The failure message and the armed state COEXIST: a failed recompress leaves the row's
        // preset at Balanced while the selector still says Smallest, so the row is armed again —
        // and the message must survive that, or the user is told nothing about what just failed.
        // This is the pair the view's `lead(for:)` has to resolve in the error's favour.
        XCTAssertEqual(model.recompressState(for: job), .armed(.smallestSize),
                       "a failed attempt does not record a preset, so the row re-arms (R1)")
    }

    /// R12's message survives until the user moves on, and no longer: changing preset is the user
    /// saying "never mind that, what about this?", and the next run clears it as stale.
    func testARecompressErrorClearsWhenThePresetChangesOrTheNextRunStarts() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        env.stub.throwOnCall = env.stub.callCount + 1
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNotNil(model.recompressErrors[job.id])

        model.preset = .maximumQuality
        XCTAssertNil(model.recompressErrors[job.id],
                     "the user moved on; a message about the Smallest attempt is now stale")

        // The SECOND half of this test's own name: the next run clears it too. Fail the row again
        // (the preset change re-armed it at Maximum quality), then start a fresh run and assert the
        // message is gone — `compress()` clears `recompressErrors` at the START of the run, so it
        // must be absent while that run is still in flight, not merely after it settles.
        env.stub.throwOnCall = env.stub.callCount + 1
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        XCTAssertNotNil(model.recompressErrors[job.id], "the Maximum-quality attempt failed too")

        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        // The preset is deliberately LEFT at Maximum quality: a failed recompress records no
        // preset (R1), so the row is still armed at it and a fresh run needs no preset change.
        // Only the run's own clear can green the assertion below — the preset half this test
        // already covered cannot.
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }
        XCTAssertNil(model.recompressErrors[job.id],
                     "the next run clears the previous run's messages at its start")
        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
    }

    /// R9 + R12: cancelling during the QUEUE phase must stop the recompress phase before it
    /// starts. `queue.run` returns normally after a cancel, so nothing about the queue's own
    /// unwinding prevents phase 2 — only the run-scoped guard does.
    func testCancellingDuringTheQueuePhaseNeverStartsTheRecompressPhase() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        // A newly queued row to occupy phase 1, and the finished row armed for phase 2.
        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount

        model.preset = .smallestSize
        model.compress()
        // Phase 1's job is in the engine, behind the gate.
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }

        XCTAssertEqual(env.stub.callCount, callsBefore + 1,
                       "the armed row must never reach the engine after a cancel in phase 1")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes,
                       "the armed row's delivered file is exactly as it was")
        XCTAssertNil(model.recompressErrors[try XCTUnwrap(model.jobs.first).id],
                     "a cancel is not a failure")
    }

    /// R9: cancelling an IN-FLIGHT recompress leaves the row's previous result and display
    /// untouched.
    ///
    /// The wait is on the stub's call count, deliberately, not on `model.isRunning`: with the
    /// run-scoped cancel guard in place, `isRunning` goes true before phase 2 begins, so a cancel
    /// fired on that signal alone would be caught by the guard and the engine would never be
    /// entered — the test would pass without ever exercising in-flight cancellation. Waiting for
    /// the call means the engine is genuinely suspended at the gate when the cancel lands.
    /// (`testCancellingDuringTheQueuePhaseNeverStartsTheRecompressPhase` covers the other case.)
    func testCancellingARecompressKeepsThePreviousResult() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount
        model.preset = .smallestSize
        model.compress()
        // The armed row is inside the engine, suspended at the gate — see the note above.
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        model.cancel()
        await gate.open()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)
        XCTAssertEqual(model.versions(for: job)?.shipped?.preset, .balanced)
        XCTAssertNil(model.recompressErrors[job.id], "a cancel is not a failure")
    }

    /// R12: a no-gain recompress ships nothing and clears NOTHING — the shipped version, its URL
    /// and its parked versions all survive, and the row remembers the futile preset (R6).
    func testNoGainRecompressKeepsEveryReference() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let before = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first)))

        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let after = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(after.shipped, before.shipped, "nothing shipped, so nothing changed")
        XCTAssertEqual(after.runnerUp, before.runnerUp)
        XCTAssertNil(after.previous)
        XCTAssertEqual(try fileSize(try XCTUnwrap(after.shipped?.url)), HeavyEnv.heavyBytes)
        XCTAssertEqual(model.recompressState(for: job), .futile(.smallestSize))
    }

    /// R11: the output path is pinned to the row's existing result even when "Save to" changed
    /// since the first run — a recompress replaces a file, it does not deliver a second one.
    func testRecompressWritesToTheRowsExistingResultPathAfterTheFolderChanged() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        let elsewhere = env.storeRoot.deletingLastPathComponent()
            .appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        model.outputFolder = elsewhere

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        XCTAssertEqual(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url, shippedURL)
        XCTAssertEqual(try fileSize(shippedURL), 700)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: elsewhere.path)).isEmpty,
                      "a recompress must not deliver a second file into the new folder")
    }

    /// R11's reservation seeding: the commit makes the row's file transiently absent, so a queued
    /// same-basename job must be kept off that path by the RESERVATION, not by the file happening
    /// to exist when names are allocated. The DECOY is what makes this test discriminate: it
    /// pushes the armed row off the first free name, so with the seeding deleted the second
    /// batch's unfiltered allocation loop re-hands that row's freed name to the armed row and
    /// gives the NEW job exactly the armed row's shipped path.
    func testAQueuedJobNeverClaimsAnArmedRowsResultPath() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let outputFolder = try XCTUnwrap(model.outputFolder)
        // The decoy occupies `image-compressed.pdf`, so the armed row ships at
        // `image-compressed-1.pdf` rather than the first free name.
        let decoy = outputFolder.appendingPathComponent("image-compressed.pdf")
        try Data().write(to: decoy)

        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let armedRowOutput = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        // Stand in for the promote window: the row's delivered file is momentarily not on disk —
        // and the decoy goes too, so `image-compressed.pdf` is free again and NOTHING on disk
        // stands between the new job and the armed row's path except the reservation.
        try FileManager.default.removeItem(at: decoy)
        try FileManager.default.removeItem(at: armedRowOutput)

        model.add([try Fixtures.imagePDF()])       // same basename, different folder
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 10) { !model.isRunning }

        let newRow = try XCTUnwrap(model.jobs.last)
        XCTAssertNotEqual(newRow.resultURL, armedRowOutput,
                          "the armed row's output must be reserved before any name is allocated")
    }

    /// R10: a vanished original stops that row before it starts, says so, and leaves its shipped
    /// result and versions intact. The rest of the batch is unaffected.
    func testMissingOriginalReportsPerRowAndLeavesTheResultIntact() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        let shippedURL = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.shipped?.url)

        try FileManager.default.removeItem(at: env.input)
        let callsBefore = env.stub.callCount
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(env.stub.callCount, callsBefore, "no engine run without an input")
        XCTAssertEqual(model.recompressErrors[job.id], "The original file is no longer where it was")
        XCTAssertEqual(try fileSize(shippedURL), HeavyEnv.heavyBytes)
        XCTAssertNotNil(model.versions(for: job)?.shipped)
    }

    // MARK: one run, two phases (R5/R9)

    /// R5: newly added files and armed rows form ONE run behind one button. The counts the button
    /// is titled from must see both sets.
    func testMixedRunCountsBothSets() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(model.armedCount, 0)

        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        XCTAssertEqual(model.pendingCount, 1, "only queued: the button reads Compress")
        XCTAssertEqual(model.armedCount, 0)

        model.preset = .smallestSize
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertEqual(model.armedCount, 1, "both sets: the button reads Compress K · Recompress M")
        XCTAssertTrue(model.canCompress)
    }

    /// The armed set alone is enough to arm the button — with nothing queued, "Recompress N PDFs"
    /// must still be pressable.
    func testArmedRowsAloneEnableTheButton() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        XCTAssertFalse(model.canCompress)

        model.preset = .smallestSize
        XCTAssertTrue(model.canCompress)
    }

    /// Risk 2's resolution, asserted: the recompress phase does not start until the queue phase is
    /// done, so the two mechanisms never run at once and the batch width is never doubled.
    func testTheRecompressPhaseWaitsForTheQueuePhase() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        model.add([try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        let callsBefore = env.stub.callCount

        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { env.stub.callCount == callsBefore + 1 }
        // The queued job is suspended in the engine. The armed row must not have started.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(env.stub.callCount, callsBefore + 1,
                       "the armed row must wait for the queue phase to finish")

        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
        XCTAssertEqual(env.stub.callCount, callsBefore + 2)
    }

    /// R9's progress bar is scoped to THIS run's rows: a recompress of one row among several
    /// finished ones opens at zero, not at "already mostly done".
    func testRunProgressIsScopedToTheRunsOwnRows() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input, try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.compress()
        try await waitUntil(timeout: 10) { !model.isRunning }

        let gate = Gate()
        env.stub.gate = gate
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        let armed = model.armedCount
        model.compress()
        try await waitUntil(timeout: 5) { model.isRunning }

        XCTAssertEqual(model.runTotalCount, armed, "the denominator is this run's rows only")
        XCTAssertEqual(model.runFinishedCount, 0, "nothing in this run has finished yet")
        XCTAssertLessThan(model.runProgress, 1.0)

        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
    }

    /// `recordTerminalRunRows` exists so a `.failed` queued row still counts toward the bar: a
    /// failure carries no outcome, so the outcome-driven path never sees it and the run would
    /// stall for ever one row short. Asserted mid-run, because the counters are cleared the
    /// moment the batch ends.
    func testAFailedQueuedRowStillCountsTowardTheProgressBar() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let gate = Gate()
        env.stub.gate = gate
        env.stub.throwOnCall = 1
        model.add([env.input, try Fixtures.bornDigitalPDF()])
        try await waitUntil(timeout: 5) { model.jobs.count == 2 }
        model.compress()

        // The gate holds only the SECOND call: the stub throws before it reaches `gate.wait()`, so
        // the failing row is the only one that can reach a terminal state here.
        try await waitUntil(timeout: 10) { model.runFinishedCount == 1 }
        XCTAssertNotNil(model.jobs.first { if case .failed = $0.state { return true } else { return false } },
                        "the row the counter moved for is the failed one")
        XCTAssertEqual(model.runTotalCount, 2)
        XCTAssertGreaterThanOrEqual(model.runProgress, 0.5, "the failed row counts, it does not stall")

        await gate.open()
        try await waitUntil(timeout: 10) { !model.isRunning }
    }

    // MARK: armed-state aggregates and cache lifecycle (R4/R17/R18)

    /// R4 hides the success banner and the "Reveal in Finder" / "Compress More" affordances while
    /// anything is armed — all three hang off `allFinished`, which must therefore stop being true.
    func testAllFinishedIsFalseWhileARowIsArmed() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        XCTAssertTrue(model.allFinished)

        model.preset = .smallestSize
        XCTAssertFalse(model.allFinished, "an armed row means the batch is not finished")

        model.preset = .balanced
        XCTAssertTrue(model.allFinished, "disarming restores the finished state exactly")
    }

    /// R18/D6: "Clear finished" discards the cleared rows' parked files — the previous version
    /// included, not just the runner-up.
    func testClearFinishedDiscardsTheParkedPreviousVersion() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }
        let previous = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first))?.previous?.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))

        model.clearFinished()
        try await waitUntil(timeout: 5) { model.jobs.isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path),
                       "the parked previous version must go with the row")
    }

    /// R15: the capsule renders on ANY row with two or more versions — including a plain
    /// (non-heavy) result that gained a previous version from a recompress.
    func testAPlainResultWithAPreviousVersionOffersTheCapsule() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        // A Maximum-quality re-run that comes back plain gs — no runner-up at all.
        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 2_000),
                                          shippedBytes: 2_000, runnerUpBytes: nil) }
        model.preset = .maximumQuality
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let row = try XCTUnwrap(model.versions(for: try XCTUnwrap(model.jobs.first)))
        XCTAssertNil(row.runnerUp, "the re-run shipped plain gs, so there is no runner-up")
        XCTAssertEqual(row.count, 2, "current + previous still draws the capsule")
        XCTAssertEqual(row.capsuleTitle, "Versions")
    }

    // MARK: the armed banner's arithmetic (R4)

    /// `armedSummary.extraSaving` is the banner's only number and Task 8's prediction feeds it, so
    /// all three of its branches are pinned here — the untestable consumer (`armedDetail`, private
    /// to a `View`) is the argument FOR asserting at the model, not against asserting at all.
    /// Branch 1: a confident armed row moving to a smaller preset contributes a positive extra.
    func testArmedSummarySumsThePredictedExtraSaving() async throws {
        // Task 8's proven confident pair: `.scanColour` shipped MRC at Balanced and armed at
        // Smallest Size keeps `targetWantsMRC == shippedWasMRC == true`, so the calibration branch
        // runs and a confident number exists.
        let env = try HeavyEnv(contentType: .scanColour)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        let analysis = try XCTUnwrap(model.analysis(for: job))
        // The premise, measured rather than assumed: the sign of `extraSaving` is the sign of
        // `balanced - smallest` in the estimator's own figures, because the prediction is the
        // shipped size scaled by that ratio.
        XCTAssertLessThan(try XCTUnwrap(analysis.estimates[.smallestSize]?.predictedBytes),
                          try XCTUnwrap(analysis.estimates[.balanced]?.predictedBytes),
                          "the estimator must rate Smallest Size below Balanced for this row")

        // Read the prediction back rather than recomputing it: `Int(_:)` truncates, and a
        // differently bracketed expression of the same real number lands a byte away.
        let predicted = try XCTUnwrap(model.recompressPrediction(for: job, at: .smallestSize))
        let summary = try XCTUnwrap(model.armedSummary)
        XCTAssertEqual(summary.armedCount, 1)
        XCTAssertEqual(summary.queuedCount, 0)
        XCTAssertEqual(summary.extraSaving, HeavyEnv.heavyBytes - predicted)
        XCTAssertGreaterThan(try XCTUnwrap(summary.extraSaving), 0,
                             "the banner reads \u{2248} saves another N")
    }

    /// Branch 2: moving UP in quality predicts a bigger file, so the extra is zero or negative —
    /// the banner must be able to say "files may grow for the extra quality" rather than show a
    /// negative saving. The row is shipped at Smallest Size and armed at Balanced, the same
    /// repeating-path pair in reverse, over a large original so the "must beat the original" guard
    /// cannot suppress the prediction and send this test down the nil branch instead.
    func testArmedSummaryGoesNonPositiveWhenTheArmedPresetIsLessAggressive() async throws {
        let env = try HeavyEnv(before: 50_000_000, contentType: .scanColour)
        let model = env.model
        model.preset = .smallestSize
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        model.preset = .balanced
        let job = try XCTUnwrap(model.jobs.first)
        let predicted = try XCTUnwrap(model.recompressPrediction(for: job, at: .balanced),
                                      "the prediction must exist, or this asserts the nil branch")
        XCTAssertGreaterThan(predicted, HeavyEnv.heavyBytes,
                             "Balanced is rated above Smallest Size, so the scaled figure grows")
        let summary = try XCTUnwrap(model.armedSummary)
        XCTAssertEqual(summary.extraSaving, HeavyEnv.heavyBytes - predicted)
        XCTAssertLessThanOrEqual(try XCTUnwrap(summary.extraSaving), 0)
    }

    /// Branch 3: no armed row has a confident prediction ⇒ `extraSaving` is nil, so the banner
    /// shows no detail line rather than a fabricated zero. `armedCount` is asserted alongside it,
    /// or "nil because there is no summary at all" would pass for the wrong reason.
    func testArmedSummaryWithholdsTheExtraWhenNoRowPredictsConfidently() async throws {
        // Task 8's proven no-confident-prediction pair: `.bornDigital` is never MRC-eligible while
        // `HeavyEnv` always ships MRC, so the raw multi-megabyte estimate is used and the "must
        // beat the original" guard fires against the 1 kB original.
        let env = try HeavyEnv(before: 1_000, contentType: .bornDigital)
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }

        model.preset = .maximumQuality
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertNil(model.recompressPrediction(for: job, at: .maximumQuality))
        let summary = try XCTUnwrap(model.armedSummary)
        XCTAssertEqual(summary.armedCount, 1, "the row IS armed — the number is what is missing")
        XCTAssertNil(summary.extraSaving)
    }

    // MARK: the previous version, end to end (R7/R15)

    /// R7's third card: "Use this" on the PREVIOUS version swaps the delivered file back, records
    /// and all. The whole point of parking it is that this costs no engine call, so the engine must
    /// not be entered — and the file on disk must actually change, not just the record describing it.
    func testUsingThePreviousVersionSwapsTheDeliveredFileBack() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        var job = try XCTUnwrap(model.jobs.first)
        var row = try XCTUnwrap(model.versions(for: job))
        let deliveredURL = try XCTUnwrap(row.shipped?.url)
        XCTAssertEqual(row.shipped?.bytes, 700)
        XCTAssertEqual(row.shipped?.preset, .smallestSize)
        XCTAssertEqual(row.previous?.bytes, HeavyEnv.heavyBytes)
        XCTAssertEqual(row.previous?.preset, .balanced)
        XCTAssertEqual(try fileSize(deliveredURL), 700)
        let callsBefore = env.stub.callCount

        await model.useVersion(.previous, for: job)

        job = try XCTUnwrap(model.jobs.first)
        row = try XCTUnwrap(model.versions(for: job))
        XCTAssertEqual(env.stub.callCount, callsBefore, "an instant switch enters no engine")
        XCTAssertEqual(row.shipped?.bytes, HeavyEnv.heavyBytes, "the previous version is shipped")
        XCTAssertEqual(row.shipped?.preset, .balanced)
        XCTAssertEqual(row.previous?.bytes, 700, "…and the Smallest result takes the previous slot")
        XCTAssertEqual(row.previous?.preset, .smallestSize)
        XCTAssertEqual(row.shipped?.url, deliveredURL, "the delivered path is stable across a switch")
        // The record is not the proof: the user's own file at that path must now hold the other
        // version's content.
        XCTAssertEqual(try fileSize(deliveredURL), HeavyEnv.heavyBytes)
    }

    /// A vanished PREVIOUS version can never be regenerated (a re-run reproduces the row's own
    /// preset, not the previous one), so it must say so beside the row and drop the slot — while
    /// leaving the perfectly good delivered result exactly where it is.
    func testUsingAVanishedPreviousVersionReportsItAndDropsTheSlot() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        env.stub.script = { _, _ in .init(outcome: .compressed(before: 9000, after: 700),
                                          shippedBytes: 700, runnerUpBytes: nil) }
        model.preset = .smallestSize
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        let job = try XCTUnwrap(model.jobs.first)
        let previous = try XCTUnwrap(model.versions(for: job)?.previous?.url)
        try FileManager.default.removeItem(at: previous)
        let callsBefore = env.stub.callCount

        await model.useVersion(.previous, for: job)

        XCTAssertEqual(env.stub.callCount, callsBefore, "a vanished previous is never re-run")
        XCTAssertNil(model.versions(for: job)?.previous, "the slot is dropped, not left dangling")
        XCTAssertEqual(model.recompressErrors[job.id],
                       "That version is no longer available — recompress at "
                       + "\(CompressPreset.balanced.title) to get it back.")
        XCTAssertEqual(model.versions(for: job)?.shipped?.bytes, 700,
                       "a message beside the row, never a failure that hides a good result")
    }

    // MARK: lead derivation (R2/R6/R10/R12)

    /// A no-gain row renders `.unchanged` (no shipped version ⇒ no size cluster) AND arms — the
    /// pair that made the armed pill invisible on exactly the rows R1 names as its user. Both
    /// halves must hold at once, which is what the view's `.unchanged` lead slot exists to draw.
    func testANoGainRowIsBothUnchangedAndArmed() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.script = { _, _ in .init(outcome: .noGain(bytes: 9000),
                                          shippedBytes: nil, runnerUpBytes: nil) }
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { !model.isRunning }

        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        // Both halves, or the nil below would also pass for "there is no row at all" — the wrong
        // reason entirely, and one that would hide a broken no-gain ingest.
        XCTAssertNotNil(model.versions(for: job), "the no-gain attempt IS recorded")
        XCTAssertNil(model.versions(for: job)?.shipped,
                     "…and shipped nothing ⇒ the view renders this row `.unchanged`")
        XCTAssertEqual(model.recompressState(for: job), .armed(.smallestSize),
                       "…and it is armed, so the `.unchanged` cluster must carry a lead")

        // The same row, futile: the neutral pill lives in that same slot.
        model.preset = .balanced
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .futile(.balanced))
    }

    /// R10 at arming time: an armed row whose original is gone yields no prediction, which is the
    /// signal the view turns into the error lead instead of a confident pill.
    func testAnArmedRowWithAMissingOriginalOffersNoPrediction() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        model.add([env.input])
        try await waitUntil(timeout: 5) { model.jobs.count == 1 }
        model.compress()
        try await waitUntil(timeout: 5) { env.doneHeavyJob(model) != nil }

        try FileManager.default.removeItem(at: env.input)
        model.preset = .smallestSize
        let job = try XCTUnwrap(model.jobs.first)
        XCTAssertEqual(model.recompressState(for: job), .armed(.smallestSize))
        XCTAssertTrue(model.isOriginalMissing(for: job))
        XCTAssertNil(model.recompressPrediction(for: job, at: .smallestSize))
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

        init(before: Int = 9000, contentType: PDFContentType? = nil) throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mrc-track-b-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            storeRoot = tmp.appendingPathComponent("cache", isDirectory: true)
            let outputFolder = tmp.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: outputFolder,
                                                    withIntermediateDirectories: true)

            input = try Fixtures.imagePDF()
            stub = StubEngine(outcome: .compressedHeavy(before: before,
                                                        after: HeavyEnv.heavyBytes,
                                                        runnerUpBytes: HeavyEnv.normalBytes),
                              shippedBytes: HeavyEnv.heavyBytes,
                              runnerUpBytes: HeavyEnv.normalBytes)
            // The ONLY change to the existing body: the estimator is injected when a caller pins
            // the classification, and is the default otherwise, so every existing `HeavyEnv()`
            // call site behaves exactly as before.
            let estimator = contentType.map {
                CompressEstimator(analyser: FixedAnalyser(contentType: $0))
            } ?? CompressEstimator()
            model = CompressViewModel(engine: stub, estimator: estimator,
                                      store: RunnerUpStore(rootOverride: storeRoot))
            model.outputFolder = outputFolder
        }

        /// A `PDFAnalysing` that answers with a fixed classification, so a prediction test pins the
        /// R16 boundary rather than whatever a fixture happens to classify as.
        private struct FixedAnalyser: PDFAnalysing {
            let contentType: PDFContentType
            func pageCount(_ url: URL) throws -> Int { 1 }
            func classify(_ url: URL) throws -> PDFContentType { contentType }
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
        /// When set, handed to the caller's `mrcReport` closure — exercises the retention path.
        var reportToDeliver: MRCDocumentReport?
        var gate: Gate?
        /// What one scripted call writes and returns, so a recompress can differ from the run that
        /// produced the row.
        struct Response {
            let outcome: JobOutcome
            /// Bytes to write at the primary output, or nil to write nothing (a no-gain run).
            let shippedBytes: Int?
            /// Bytes to write at the alternate output, or nil to leave that slot empty.
            let runnerUpBytes: Int?
        }

        // `compress` runs concurrently: `ToolQueue.execute` fans out up to `performanceCoreCount`
        // jobs at once, so `callCount`, `presets`, `script` and `throwOnCall` all need genuine
        // synchronisation rather than plain mutable state. Everything below the lock keeps the same
        // external API (synchronous property access from @MainActor tests) but is backed by a
        // private, lock-guarded store.
        private let lock = NSLock()
        private var _callCount = 0
        private var _presets: [CompressPreset] = []
        private var _script: ((Int, CompressPreset) -> Response)?
        private var _throwOnCall: Int?

        /// Number of `compress` calls made so far.
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
        /// Every preset the engine was called with, in order — so a test can assert which one a
        /// re-run reproduced.
        var presets: [CompressPreset] { lock.lock(); defer { lock.unlock() }; return _presets }
        /// Per-call script (1-based call index). Nil keeps the fixed outcome the initialiser took.
        var script: ((Int, CompressPreset) -> Response)? {
            get { lock.lock(); defer { lock.unlock() }; return _script }
            set { lock.lock(); defer { lock.unlock() }; _script = newValue }
        }
        /// When set, the engine throws on this 1-based call instead of writing anything.
        var throwOnCall: Int? {
            get { lock.lock(); defer { lock.unlock() }; return _throwOnCall }
            set { lock.lock(); defer { lock.unlock() }; _throwOnCall = newValue }
        }

        init(outcome: JobOutcome, shippedBytes: Int, runnerUpBytes: Int) {
            self.outcome = outcome
            self.shippedBytes = shippedBytes
            self.runnerUpBytes = runnerUpBytes
        }

        func compress(_ input: URL, preset: CompressPreset, to output: URL,
                      alternateOutput: URL?, mrcReport: ((MRCDocumentReport) -> Void)?,
                      progress: @escaping (Double) -> Void) async throws -> JobOutcome {
            // Increment, append and decide the throw/script outcome atomically, capturing locals so
            // no other concurrent call can observe or mutate state mid-decision.
            let call: Int
            let shouldThrow: Bool
            let currentScript: ((Int, CompressPreset) -> Response)?
            lock.lock()
            _callCount += 1
            _presets.append(preset)
            call = _callCount
            shouldThrow = (_throwOnCall == call)
            currentScript = _script
            lock.unlock()
            if shouldThrow { throw CompressError.validationFailed }
            let response = currentScript?(call, preset)
                ?? Response(outcome: outcome, shippedBytes: shippedBytes, runnerUpBytes: runnerUpBytes)
            let fm = FileManager.default
            // Mirror the production engine's never-overwrite delivery contract (it `moveItem`s the
            // winner into place, which throws on an existing destination) — a stub that overwrites
            // via `Data.write` would mask a caller that targets an already-occupied destination.
            if let bytes = response.shippedBytes {
                guard !fm.fileExists(atPath: output.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try Data(repeating: 0x48, count: bytes).write(to: output)
            }
            if let alternateOutput, let bytes = response.runnerUpBytes {
                guard !fm.fileExists(atPath: alternateOutput.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try Data(repeating: 0x4E, count: bytes).write(to: alternateOutput)
            }
            if let reportToDeliver { mrcReport?(reportToDeliver) }
            if let gate { await gate.wait() }
            return response.outcome
        }
    }

    /// A one-shot latch: `wait()` suspends until `open()` is called (or returns at once if already open).
    /// A latch, not a handoff: phase 2 runs up to `performanceCoreCount` recompresses at once, so
    /// two engine calls can be suspended here simultaneously. A single stored continuation would
    /// let the second waiter overwrite (and orphan) the first.
    private actor Gate {
        private var opened = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            opened = true
            for continuation in continuations { continuation.resume() }
            continuations = []
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
