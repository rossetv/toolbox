// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

/// The queue's admission surface (spec §6.5/§6.6/§6.1): names reserved when a file is ADDED
/// rather than at run start, the ledger's invalidation triggers while the queue is idle, the
/// settings lock a run takes over its own jobs, add-time inspection, and the verb floors.
///
/// This is where drag-during-run becomes legal: `ToolQueueTests.testAddWhileRunningIsRefused`
/// and `QueueViewModelTests.testAddIsIgnoredWhileABatchIsRunning` both asserted the OLD guard and
/// are SUPERSEDED by `testAddDuringRunJoinsBatch` here. The sibling second-`run` guard SURVIVES
/// untouched — `ToolQueueTests.testSecondRunIsRefusedSoTheLiveBatchStaysCancellable` still passes.
@MainActor
final class QueueAdmissionTests: XCTestCase {

    /// A sibling temp directory for the "save somewhere else" leg, beside the env's own cache root.
    private func elsewhere(_ env: HeavyEnv) throws -> URL {
        let url = env.storeRoot.deletingLastPathComponent()
            .appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A row that has not started. `.analysing` is the view model's own published OVERLAY on a
    /// row the queue still holds as `.queued` (see `JobState.analysing`), so "not started yet" is
    /// the two of them together — asserting the bare `.queued` would race the estimator.
    private func isPending(_ state: JobState?) -> Bool {
        switch state {
        case .queued, .analysing: return true
        default: return false
        }
    }

    private func addOne(_ env: HeavyEnv, _ url: URL? = nil) async throws -> ToolJob.ID {
        let before = env.model.jobs.count
        env.model.add([url ?? env.input])
        try await waitUntil(timeout: 5) { env.model.jobs.count == before + 1 }
        return try XCTUnwrap(env.model.jobs.last).id
    }

    // MARK: drag during a run (spec §6.5)

    /// SUPERSEDES `ToolQueueTests.testAddWhileRunningIsRefused` and
    /// `QueueViewModelTests.testAddIsIgnoredWhileABatchIsRunning`: with names reserved at add time
    /// the race those guards existed to close is gone, so a file dropped mid-run joins the live
    /// batch instead of sitting `.queued` behind it.
    func testAddDuringRunJoinsBatch() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let gate = Gate()
        env.stub.gate = gate
        _ = try await addOne(env)
        model.compress()
        // The first job is inside the engine, suspended — so the batch is genuinely live and the
        // launch window still has a slot to re-poll into.
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }

        let latecomerID = try await addOne(env, try Fixtures.textImagePDF())
        XCTAssertEqual(model.jobs.count, 2, "a drop during a run must be admitted (spec §6.5)")
        XCTAssertNotNil(model.reservedDelivery(for: latecomerID),
                        "a mid-run add reserves its name at add, like every other add")

        await gate.open()
        try await waitUntil(timeout: 15) { !model.isRunning }
        for job in model.jobs {
            guard case .done = job.state else {
                return XCTFail("row \(job.url.lastPathComponent) never ran: \(job.state)")
            }
        }
        XCTAssertEqual(env.stub.callCount, 2, "the latecomer must have joined the live batch")
    }

    /// Once a run starts its destination and verb set LOCK for that run's jobs (spec §6.5), and a
    /// file added mid-run reserves against the lock — not against settings the user has moved since.
    func testAddDuringRunReservesAgainstLockedSettings() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let lockedFolder = try XCTUnwrap(model.outputFolder)
        let gate = Gate()
        env.stub.gate = gate
        _ = try await addOne(env)
        model.compress()
        try await waitUntil(timeout: 15) { env.stub.callCount == 1 }

        // The settings move under the live run.
        model.outputFolder = try elsewhere(env)
        model.ocrOn = true
        model.compressOn = false

        let latecomerID = try await addOne(env, try Fixtures.textImagePDF())
        let reserved = try XCTUnwrap(model.reservedDelivery(for: latecomerID))
        XCTAssertEqual(reserved.deletingLastPathComponent().canonical.path,
                       lockedFolder.canonical.path,
                       "a mid-run add reserves in the folder the run locked")
        XCTAssertTrue(reserved.lastPathComponent.hasSuffix("-compressed.pdf"),
                      "a mid-run add reserves under the verb set the run locked, got \(reserved.lastPathComponent)")

        await gate.open()
        try await waitUntil(timeout: 15) { !model.isRunning }
    }

    // MARK: releasing reservations (spec §6.5)

    func testReservationReleasedOnRemove() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await addOne(env)
        let reserved = try XCTUnwrap(model.reservedDelivery(for: id))

        // A `.queued` row on purpose: `ToolQueue.remove` only removes those, so this is the one
        // path where the row genuinely leaves the queue and its ledger entry with it.
        model.remove(try XCTUnwrap(model.jobs.first))
        try await waitUntil(timeout: 5) { model.jobs.isEmpty }
        XCTAssertNil(model.reservedDelivery(for: id), "a removed row releases its reservations")

        let reID = try await addOne(env)
        XCTAssertEqual(model.reservedDelivery(for: reID), reserved,
                       "the freed name must go straight back to the next add, unsuffixed")
    }

    /// ⊗ Clear releases the cleared rows' reservations, so re-adding the same file is not pushed
    /// onto `-compressed-1.pdf` by a ledger entry nothing owns any more. The run is a NO-GAIN so
    /// nothing lands on disk — an on-disk file would suffix the re-add regardless of the ledger,
    /// and this test is about the ledger.
    func testClearReleasesReservationsAndReAddDoesNotSuffix() async throws {
        let env = try HeavyEnv()
        let model = env.model
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9000), shippedBytes: nil, runnerUpBytes: nil)
        }
        let id = try await addOne(env)
        let reserved = try XCTUnwrap(model.reservedDelivery(for: id))

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }
        model.clearFinished()
        try await waitUntil(timeout: 5) { model.jobs.isEmpty }
        XCTAssertNil(model.reservedDelivery(for: id))

        let reID = try await addOne(env)
        XCTAssertEqual(model.reservedDelivery(for: reID), reserved,
                       "⊗ Clear must release the cleared rows' reservations")
    }

    // MARK: ledger invalidation while idle (spec §6.5's four triggers)

    func testFolderChangeReReservesWhileIdle() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await addOne(env)
        let destination = try elsewhere(env)

        model.outputFolder = destination

        let reserved = try XCTUnwrap(model.reservedDelivery(for: id))
        XCTAssertEqual(reserved.deletingLastPathComponent().canonical.path,
                       destination.canonical.path,
                       "a save-destination change while idle re-reserves the row")
    }

    /// Delivered suffixes are pinned by spec §6.5: any run including Compress delivers
    /// `-compressed.pdf`; an OCR-only run delivers `-ocr.pdf`. Toggling the batch verb set while
    /// idle re-reserves under the new suffix, and drops the runner-up name an OCR-only row can
    /// never produce.
    func testVerbSetChangeFlipsSuffix() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await addOne(env)
        XCTAssertTrue(try XCTUnwrap(model.reservedDelivery(for: id))
            .lastPathComponent.hasSuffix("-compressed.pdf"))
        XCTAssertNotNil(model.reservedAlternate(for: id))

        model.ocrOn = true
        model.compressOn = false

        XCTAssertTrue(try XCTUnwrap(model.reservedDelivery(for: id))
            .lastPathComponent.hasSuffix("-ocr.pdf"),
                      "an OCR-only run delivers <name>-ocr.pdf")
        XCTAssertNil(model.reservedAlternate(for: id),
                     "an OCR-only row runs no compress leg, so it can retain no runner-up")

        model.compressOn = true
        XCTAssertTrue(try XCTUnwrap(model.reservedDelivery(for: id))
            .lastPathComponent.hasSuffix("-compressed.pdf"),
                      "turning Compress back on re-reserves the compressed name")
    }

    /// SUPERSEDES the plan's `testPerRowOCROverrideFlipsSuffix`, which is unreachable: the
    /// delivered suffix keys on whether the row's effective verb set includes COMPRESS, and
    /// Compress is batch-level only — spec §6.1 lists exactly three per-row overrides
    /// (`preset`, `rebuildScan`, `ocr`) and design screen 04c offers exactly three controls
    /// (Quality, Rebuild the scan, Read the text). No per-row control can therefore move the
    /// suffix; spec §11's per-row suffix-switch leg over-reached. The batch leg is covered by
    /// `testVerbSetChangeFlipsSuffix` above. Reported as a spec defect.
    func testPerRowOCROverrideLeavesTheSuffixToTheBatchCompressVerb() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await addOne(env)

        model.setOverride(RowOverride(ocr: true), for: id)
        XCTAssertTrue(try XCTUnwrap(model.reservedDelivery(for: id))
            .lastPathComponent.hasSuffix("-compressed.pdf"),
                      "a row opting into OCR still ships a compressed file")

        model.setOverride(RowOverride(ocr: false), for: id)
        XCTAssertTrue(try XCTUnwrap(model.reservedDelivery(for: id))
            .lastPathComponent.hasSuffix("-compressed.pdf"),
                      "a row opting out of OCR still ships a compressed file")

        // And on an OCR-only batch the row keeps `-ocr.pdf` in BOTH directions: opting out is
        // refused by the per-row verb floor (spec §6.1), so the suffix cannot move that way either.
        model.ocrOn = true
        model.compressOn = false
        for override in [RowOverride(ocr: true), RowOverride(ocr: false)] {
            model.setOverride(override, for: id)
            XCTAssertTrue(try XCTUnwrap(model.reservedDelivery(for: id))
                .lastPathComponent.hasSuffix("-ocr.pdf"))
        }
    }

    /// The `rebuildScan` opt-out removes the only name a rebuild would need; opting back in
    /// reserves it again (spec §6.5's "a `rebuildScan` change adds/removes the alternate name").
    func testRebuildScanFlipAddsAndRemovesAlternateReservation() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await addOne(env)
        let alternate = try XCTUnwrap(model.reservedAlternate(for: id))

        model.setOverride(RowOverride(rebuildScan: false), for: id)
        XCTAssertNil(model.reservedAlternate(for: id),
                     "a row that will not be rebuilt needs no runner-up name")

        model.setOverride(RowOverride(rebuildScan: true), for: id)
        XCTAssertEqual(model.reservedAlternate(for: id), alternate,
                       "opting back in re-reserves the same free name")
    }

    func testRebindReReservesWhileIdle() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await addOne(env)
        let before = try XCTUnwrap(model.reservedDelivery(for: id))

        let replacement = try Fixtures.textImagePDF()
        model.rebind(id, to: replacement)

        let after = try XCTUnwrap(model.reservedDelivery(for: id))
        XCTAssertNotEqual(after, before)
        XCTAssertTrue(after.lastPathComponent.hasPrefix(
            replacement.deletingPathExtension().lastPathComponent),
                      "a rebind re-reserves against the file the row now points at, got \(after.lastPathComponent)")
    }

    /// "Find it…" is a FULL state reset: the problem goes, the row re-enters `canStart`'s healthy
    /// count, and the estimate is re-derived from the new file rather than left stale.
    func testRebindClearsProblemAndRequeuesRow() async throws {
        let env = try HeavyEnv(timeBudget: 5)
        let model = env.model
        let id = try await addOne(env, try Fixtures.corruptPDF())
        try await waitUntil(timeout: 5) { model.inspections[id]?.problem != nil }
        XCTAssertEqual(model.inspections[id]?.problem, .unreadable)
        XCTAssertFalse(model.canStart, "a queue of nothing but problem rows cannot start")

        model.rebind(id, to: env.input)

        try await waitUntil(timeout: 5) { model.inspections[id]?.problem == nil }
        XCTAssertTrue(isPending(model.jobs.first?.state))
        XCTAssertTrue(model.canStart, "the rebound row rejoins the healthy count")
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }
        XCTAssertEqual(model.jobs.first?.estimate?.isFallback, false,
                       "the rebind re-analyses; a stale fallback estimate would price the old file")

        // The same reset reaches a row that FAILED rather than one that arrived broken.
        let failing = try HeavyEnv()
        failing.stub.throwOnCall = 1
        _ = try await addOne(failing)
        failing.model.compress()
        try await waitUntil(timeout: 15) { !failing.model.isRunning }
        let failedID = try XCTUnwrap(failing.model.jobs.first).id
        guard case .failed = try XCTUnwrap(failing.model.jobs.first).state else {
            return XCTFail("expected a failed row to rebind from")
        }
        failing.model.rebind(failedID, to: try Fixtures.textImagePDF())
        XCTAssertTrue(isPending(failing.model.jobs.first?.state),
                      "a rebind returns even a failed row to the start of its life")
    }

    // MARK: verb floors and the Start gate (spec §6.1)

    /// No row can reach "nothing to do" through overrides: on a Compress-off batch the row's OCR
    /// toggle is its LAST verb, and turning it off is refused.
    func testOverrideVerbFloorBlocksLastVerbOff() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await addOne(env)
        model.ocrOn = true
        model.compressOn = false

        model.setOverride(RowOverride(ocr: false), for: id)

        let verbs = model.effectiveVerbs(for: id)
        XCTAssertFalse(verbs.compress)
        XCTAssertTrue(verbs.ocr, "the floor keeps the row's last verb on (spec §6.1)")
    }

    /// The other direction of spec §6.10's mutual exclusion: `SelfUpdater.isBusy` refuses an
    /// update while a batch runs, but nothing previously refused a batch started AFTER the swap
    /// began — the aside-swap + terminate would then land mid-batch, killing the run unannounced.
    func testCanStartRefusedWhileUpdating() async throws {
        var updating = false
        let env = try HeavyEnv(isUpdating: { updating })
        let model = env.model
        _ = try await addOne(env)
        XCTAssertTrue(model.canStart)

        updating = true
        XCTAssertFalse(model.canStart, "a batch must not start into a swap already in flight")

        updating = false
        XCTAssertTrue(model.canStart, "the update finishing (e.g. .failed) unblocks Start again")
    }

    func testZeroVerbsDisablesStart() async throws {
        let env = try HeavyEnv()
        let model = env.model
        _ = try await addOne(env)
        XCTAssertTrue(model.canStart)

        model.compressOn = false
        XCTAssertFalse(model.canStart, "zero verbs ⇒ Start disabled (spec §6.1)")

        model.ocrOn = true
        XCTAssertTrue(model.canStart, "one verb is enough")
    }

    /// A row that could not be opened at add time is not work the batch can do, so it must not
    /// enable Start on its own — nor may a row the user has skipped.
    func testProblemRowExcludedFromCanStart() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let brokenID = try await addOne(env, try Fixtures.corruptPDF())
        try await waitUntil(timeout: 5) { model.inspections[brokenID]?.problem != nil }
        XCTAssertFalse(model.canStart, "a problem row is not a healthy row")

        let healthyID = try await addOne(env)
        XCTAssertTrue(model.canStart)

        model.setSkipped(true, for: healthyID)
        XCTAssertFalse(model.canStart, "a skipped row is excluded from the healthy count too")

        model.setSkipped(false, for: healthyID)
        XCTAssertTrue(model.canStart)
    }

    /// A skipped row is excluded from the run itself, not merely from the button: it stays in the
    /// list, `.queued` and untouched, and the engine is never asked to look at it.
    func testSkippedRowIsExcludedFromTheRun() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let skippedID = try await addOne(env)
        _ = try await addOne(env, try Fixtures.textImagePDF())

        model.setSkipped(true, for: skippedID)
        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(env.stub.callCount, 1, "the skipped row must never reach the engine")
        XCTAssertTrue(isPending(model.jobs.first(where: { $0.id == skippedID })?.state),
                      "a skipped row is left exactly as it was — never run, never failed")
    }

    // MARK: row-scoped preset state (spec §6.1, step 5)

    /// Arming compares against the ROW's effective preset, not the batch's: an override that
    /// already matches the row's own preset leaves it alone even when the batch has moved.
    func testArmingUsesRowEffectivePreset() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        let job = try await env.runToDone()

        // The batch moves; without an override the row arms at the batch's preset.
        model.preset = .smallestSize
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .armed(.smallestSize))

        // The row overrides back to its OWN preset: nothing to recompress, so it disarms.
        model.setOverride(RowOverride(preset: .balanced), for: job.id)
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)), .none,
                       "an overridden row is measured against its own effective preset")
    }

    /// Futility is keyed by `(id, effective preset, verb set)`: a no-gain at one verb set says
    /// nothing about a run that also reads the text, so adding OCR must re-open the row.
    func testFutilityKeyIncludesVerbSet() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        env.stub.script = { _, _ in
            .init(outcome: .noGain(bytes: 9000), shippedBytes: nil, runnerUpBytes: nil)
        }
        _ = try await addOne(env)
        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                       .futile(.balanced), "a no-gain at this preset and verb set is futile")

        model.ocrOn = true
        XCTAssertNotEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)),
                          .futile(.balanced),
                          "the futile record belongs to the verb set that produced it")
    }

    /// The analysis is cached per FILE but priced against the row's rebuild opt-out (spec §6.7),
    /// so flipping "Rebuild the scan" while the queue is idle must RE-PRICE the row: the cached
    /// figure was the rebuild's, and the row will now take the gs-only path. Sibling of the
    /// reservation invalidation asserted above.
    func testRebuildOptOutRepricesRowEstimate() async throws {
        let env = try HeavyEnv(contentType: .scanColour, timeBudget: 5)
        let model = env.model
        model.preset = .balanced
        let id = try await addOne(env)
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }
        let rebuilt = try XCTUnwrap(model.jobs.first?.estimate?.predictedBytes)

        model.setOverride(RowOverride(rebuildScan: false), for: id)
        try await waitUntil(timeout: 5) {
            (model.jobs.first?.estimate?.predictedBytes ?? rebuilt) != rebuilt
        }

        XCTAssertGreaterThan(try XCTUnwrap(model.jobs.first?.estimate?.predictedBytes), rebuilt,
                             "a row that will not be rebuilt must be priced on the gs-only path")

        model.setOverride(nil, for: id)
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate?.predictedBytes == rebuilt }
        XCTAssertEqual(model.jobs.first?.estimate?.predictedBytes, rebuilt,
                       "opting back in restores the rebuild's own figure")
    }

    /// The row's displayed estimate is keyed by the row's own preset — showing the batch preset's
    /// number on an overridden row is two different figures for one file.
    func testOverriddenRowEstimateUsesRowPreset() async throws {
        let env = try HeavyEnv(timeBudget: 5)
        let model = env.model
        model.preset = .maximumQuality
        let id = try await addOne(env)
        try await waitUntil(timeout: 5) { model.jobs.first?.estimate != nil }
        let analysis = try XCTUnwrap(model.analysis(for: try XCTUnwrap(model.jobs.first)))
        let atSmallest = try XCTUnwrap(analysis.estimates[.smallestSize]?.predictedBytes)
        let atMaximum = try XCTUnwrap(analysis.estimates[.maximumQuality]?.predictedBytes)
        XCTAssertNotEqual(atSmallest, atMaximum, "the fixture must price the two presets apart")
        XCTAssertEqual(model.jobs.first?.estimate?.predictedBytes, atMaximum)

        model.setOverride(RowOverride(preset: .smallestSize), for: id)

        XCTAssertEqual(model.jobs.first?.estimate?.predictedBytes, atSmallest,
                       "an overridden row shows the estimate for the preset it will run at")
    }

    /// R16's provenance, re-derived per row: the preset recorded against the delivered version is
    /// the one the row actually ran at, or a later `recompressState` reads the row against a
    /// preset it was never compressed at.
    func testOverriddenRowRecordsItsOwnPresetAsProvenance() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        let id = try await addOne(env)
        model.setOverride(RowOverride(preset: .maximumQuality), for: id)

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        XCTAssertEqual(env.stub.presets, [.maximumQuality],
                       "the row is dispatched at its own preset")
        XCTAssertEqual(model.versions(for: try XCTUnwrap(model.jobs.first))?.rowPreset,
                       .maximumQuality,
                       "and the version it delivered records that preset, not the batch's")
    }

    // MARK: add-time inspection (spec §6.6)

    func testInspectionProducesTheReadyScreenMetaLine() async throws {
        let env = try HeavyEnv(timeBudget: 5)
        let model = env.model
        let id = try await addOne(env, try Fixtures.bornDigitalPDF(pages: 3))
        try await waitUntil(timeout: 5) {
            model.inspections[id]?.pageCount != nil && model.inspections[id]?.contentType != nil
        }

        let inspection = try XCTUnwrap(model.inspections[id])
        XCTAssertEqual(inspection.pageCount, 3)
        XCTAssertEqual(inspection.hasTextLayer, true)
        XCTAssertEqual(inspection.contentType, .bornDigital)
        XCTAssertEqual(inspection.metaLine, "3 pages, text and vectors")
        XCTAssertEqual(model.pageCount(for: try XCTUnwrap(model.jobs.first)), 3)
    }

    /// A locked file surfaces as a problem row immediately, before any run (spec §6.6) — with the
    /// handoff's own copy and no password affordance (D3).
    func testLockedFileIsAProblemRowAtAddTime() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await addOne(env, try Fixtures.encryptedPDF())
        try await waitUntil(timeout: 5) { model.inspections[id]?.problem != nil }

        XCTAssertEqual(model.inspections[id]?.problem, .locked)
        XCTAssertEqual(model.inspections[id]?.metaLine, "Needs a password to open")
    }

    /// A file that has gone between the picker and the add is a problem row, not a silent row.
    func testMissingFileIsAProblemRowAtAddTime() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let doomed = try Fixtures.imagePDF()
        try FileManager.default.removeItem(at: doomed)
        let id = try await addOne(env, doomed)
        try await waitUntil(timeout: 5) { model.inspections[id]?.problem != nil }

        XCTAssertEqual(model.inspections[id]?.problem, .missing)
        XCTAssertEqual(model.inspections[id]?.metaLine, "Moved or renamed since you added it")
    }

    // MARK: the arming exclusion (spec §7's "Choose which files…")

    func testArmedExclusionRemovesTheRowFromTheArmedSet() async throws {
        let env = try HeavyEnv()
        let model = env.model
        model.preset = .balanced
        let job = try await env.runToDone()
        model.preset = .smallestSize
        XCTAssertEqual(model.armedCount, 1)

        model.setArmedExclusion(true, for: job.id)

        XCTAssertTrue(model.armedExclusions.contains(job.id))
        XCTAssertEqual(model.recompressState(for: try XCTUnwrap(model.jobs.first)), .none)
        XCTAssertEqual(model.armedCount, 0, "an excluded row is not re-run")

        model.setArmedExclusion(false, for: job.id)
        XCTAssertEqual(model.armedCount, 1)
    }

    // MARK: the mid-run reservation switch (the ledger surface F5a's rescue drives)

    /// `reserveDelivery(suffix:for:)` is the ledger's ONE mid-run mutation: it releases whatever
    /// delivery name the row held and hands back a fresh one under the new suffix, keeping the
    /// row's runner-up reservation intact. `releaseDelivery` drops the name for a row that ships
    /// nothing at all.
    func testMidRunReservationSwitchReplacesTheDeliveryNameOnly() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await addOne(env)
        let compressed = try XCTUnwrap(model.reservedDelivery(for: id))
        let alternate = try XCTUnwrap(model.reservedAlternate(for: id))

        let rescued = try XCTUnwrap(model.reserveDelivery(suffix: "ocr", for: id))

        XCTAssertTrue(rescued.lastPathComponent.hasSuffix("-ocr.pdf"))
        XCTAssertEqual(model.reservedDelivery(for: id), rescued)
        XCTAssertEqual(model.reservedAlternate(for: id), alternate,
                       "only the delivery name changes")

        // The released `-compressed` name is free again for the next add.
        let otherID = try await addOne(env)
        XCTAssertEqual(model.reservedDelivery(for: otherID), compressed)

        model.releaseDelivery(for: id)
        XCTAssertNil(model.reservedDelivery(for: id))
    }
}
