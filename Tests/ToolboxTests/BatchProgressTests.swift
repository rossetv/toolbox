// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import XCTest
@testable import Toolbox

// Re-homing note (plan F5c, step 1): `BatchProgressTextTests` predates the redesign's per-row leg
// labels; its subject, `batchProgressText`, is unchanged here and dies only at I1b's `CompressView`
// deletion (its own file stays in place until then). Its three assertions are superseded by tests
// in THIS file as follows:
//   - `testCountsTheFileCurrentlyBeingProcessed` -> superseded by the aggregation tests below:
//     `BatchProgress.fraction` sums the batch's rows directly, so there is no "N of M" string left
//     to re-derive at all.
//   - `testClampsWhenEveryFileHasFinished` -> superseded by `testReadingPageLabelClampsAtPageCount`,
//     the exact same off-by-one shape (a late tick can report past the true count) now guarding
//     `legLabel`'s "Reading page N of M" instead of the old batch-wide "N of M…".
//   - `testUsesTheVerbItIsGiven` -> superseded by the per-leg label tests
//     (`testCompressLegLabelSwitchesAtRungCeiling`, `testReadingPageLabelClampsAtPageCount`):
//     `legLabel` chooses its own verb from the row's state ("Compressing…" / "Rebuilding scan…" /
//     "Reading page N of M"), never a caller-supplied one.
//
/// `BatchProgress` (the Working/Finished header's aggregate figures) and `QueueViewModel`'s
/// per-row progress surfaces (spec §6.8): leg composition (a two-leg row's ring is one continuous
/// fill, never two resets), the per-leg active-meta label, the per-leg and per-batch ETA gates,
/// row duration, measured page rate, and the savings-sum exclusion (spec §6.5).
@MainActor
final class BatchProgressTests: XCTestCase {

    // MARK: pure arithmetic — no live run needed

    func testReadingPageLabelClampsAtPageCount() {
        XCTAssertEqual(QueueViewModel.readingPageLabel(rawFraction: 0, pageCount: 3),
                       "Reading page 1 of 3", "never page 0 — the first page is already under way")
        XCTAssertEqual(QueueViewModel.readingPageLabel(rawFraction: 2.0 / 3.0, pageCount: 3),
                       "Reading page 2 of 3")
        XCTAssertEqual(QueueViewModel.readingPageLabel(rawFraction: 1.0, pageCount: 3),
                       "Reading page 3 of 3")
        // The regression the old `batchProgressText` clamp test documented: the job can reach
        // `.done` a MainActor hop before its published state stops reading as `.running`, so a
        // late tick's fraction can round past the true page count.
        XCTAssertEqual(QueueViewModel.readingPageLabel(rawFraction: 1.2, pageCount: 4),
                       "Reading page 4 of 4")
    }

    func testCompressLegLabelSwitchesAtRungCeiling() {
        XCTAssertEqual(QueueViewModel.compressLegLabel(rawFraction: 0.2, attemptsRebuild: true),
                       "Compressing…")
        XCTAssertEqual(QueueViewModel.compressLegLabel(
            rawFraction: CompressEngine.rungProgressCeiling, attemptsRebuild: true),
            "Rebuilding scan…")
        XCTAssertEqual(QueueViewModel.compressLegLabel(rawFraction: 0.9, attemptsRebuild: true),
                       "Rebuilding scan…")
        // A row that never attempts the rebuild has no ceiling to cross (the engine's own
        // `gsProgressCeiling` is 1.0 in that branch) — it reads "Compressing…" throughout, even
        // past where an eligible row would already have switched.
        XCTAssertEqual(QueueViewModel.compressLegLabel(rawFraction: 0.9, attemptsRebuild: false),
                       "Compressing…")
    }

    func testRowETANilBeforeTenPercentOfLeg() {
        XCTAssertNil(QueueViewModel.legETASeconds(rawFraction: 0.05, elapsed: 5),
                     "under 10% of the leg — nothing honest to say yet")
        XCTAssertNil(QueueViewModel.legETASeconds(rawFraction: 0, elapsed: 100))
        XCTAssertEqual(QueueViewModel.legETASeconds(rawFraction: 0.1, elapsed: 1), 9)
        XCTAssertEqual(QueueViewModel.legETASeconds(rawFraction: 0.5, elapsed: 5), 5)
    }

    func testBatchETANilBeforeTenPercent() {
        let (eta, rate) = QueueViewModel.smoothedETA(fraction: 0.05, elapsed: 1,
                                                      previousRate: nil, previousETA: nil)
        XCTAssertNil(eta)
        XCTAssertNil(rate, "no rate recorded either — nothing to smooth toward next tick")
    }

    /// Spec §6.8's "monotonic display": under a steady real rate the smoothed ETA must never tick
    /// UP while the batch runs, even as the EMA settles from its first, unsmoothed reading.
    func testBatchETAIsMonotonicNonIncreasing() {
        var rate: Double?
        var lastETA: Int?
        var seen: [Int] = []
        for tick in 1...9 {
            let fraction = Double(tick) / 10
            let elapsed = Double(tick)
            let (eta, newRate) = QueueViewModel.smoothedETA(fraction: fraction, elapsed: elapsed,
                                                             previousRate: rate, previousETA: lastETA)
            rate = newRate
            if let eta {
                if let last = seen.last {
                    XCTAssertLessThanOrEqual(eta, last, "tick \(tick): the countdown must not rise")
                }
                seen.append(eta)
            }
            lastETA = eta
        }
        XCTAssertFalse(seen.isEmpty)
    }

    // MARK: environment (mirrors `QueuePassTests`' own env, kept local to this file)

    /// A recognition that succeeds cleanly — enough for a rescue's or a noGain+OCR row's own OCR
    /// leg to deliver without complicating what these tests are actually checking.
    private func recognition() -> RecognisedDocument {
        RecognisedDocument(
            pageText: [0: [PositionedText(text: "HELLO",
                                          boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.04))]],
            geometry: [0: PageGeometry(mediaBox: Fixtures.letter, rotation: 0)],
            pagesRecognised: 1, pagesSkipped: 0, pageCount: 1)
    }

    // MARK: aggregation and persistence (live run — the existing stubs report no interim progress,
    // so these observe the batch transitioning between whole-row completions rather than a
    // continuous sweep; that is enough to exercise the summing itself)

    func testBatchProgressSurvivesBatchEnd() async throws {
        let env = try HeavyEnv()
        let model = env.model
        XCTAssertNil(model.batchProgress, "nothing to show before any batch has ever run")
        _ = try await env.addRow()

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let progress = try XCTUnwrap(model.batchProgress,
                                    "batchProgress must survive the run ending, not vanish with it")
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 0.0001)

        model.clearFinished()
        XCTAssertNil(model.batchProgress, "cleared once the queue that batch touched is emptied")
    }

    /// Two rows: one is rescued (its compress call throws before ever reaching the shared gate)
    /// and finishes on its own; the other has written its output and is now held on that SAME
    /// gate — so exactly one of the two reads `.done` while the batch stays open, proving the
    /// fraction sums across BOTH rows rather than reporting either one alone.
    func testBatchProgressAggregatesAcrossRows() async throws {
        let ocr = StubOCREngine(document: recognition())
        let env = try HeavyEnv(ocrEngine: ocr)
        let model = env.model
        model.ocrOn = true
        let gate = Gate()
        env.stub.gate = gate
        env.stub.throwOnCall = 1
        env.stub.errorToThrow = CompressError.ghostscriptFailed("gs died")
        model.add(Array(repeating: env.input, count: 2))
        try await waitUntil(timeout: 10) { model.jobs.count == 2 }

        model.compress()
        try await waitUntil(timeout: 15) {
            model.jobs.filter { if case .done = $0.state { return true }; return false }.count == 1
        }
        var progress = try XCTUnwrap(model.batchProgress)
        XCTAssertEqual(progress.fraction, 0.5, accuracy: 0.0001,
                       "one row finished, the other still `.running(0)` on the held gate")

        await gate.open()
        try await waitUntil(timeout: 15) { !model.isRunning }
        progress = try XCTUnwrap(model.batchProgress)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 0.0001)
    }

    func testRowDurationRecordedAtCompletion() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await env.addRow()
        XCTAssertNil(model.rowDuration(for: id), "no duration before the row has ever run")

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let duration = try XCTUnwrap(model.rowDuration(for: id))
        XCTAssertGreaterThanOrEqual(duration, 0)
    }

    func testMeasuredPageRateRecordedAfterRun() async throws {
        let env = try HeavyEnv()
        let model = env.model
        let id = try await env.addRow()
        let job = try XCTUnwrap(model.jobs.first(where: { $0.id == id }))
        try await waitUntil(timeout: 5) { model.pageCount(for: job) != nil }
        XCTAssertNil(model.measuredPageRate(for: id), "nothing measured before the row has run")

        model.compress()
        try await waitUntil(timeout: 15) { !model.isRunning }

        let rate = try XCTUnwrap(model.measuredPageRate(for: id),
                                 "a `.done` row with a known page count must expose a rate")
        XCTAssertGreaterThanOrEqual(rate, 0)
    }

    /// Spec §6.5: `savedSoFarBytes` sums COMPRESSED rows only. Three rows share one batch (compress
    /// + OCR both on) so each disposition is exercised in the same run: call 1 ships a genuine
    /// compress+OCR delivery (saves 9,000 − 1,200 = 7,800 bytes); call 2 throws a compress-specific
    /// error and is rescued (an OCR-only delivery — no `VersionStore` entry at all); call 3 comes
    /// back `.noGain` with OCR on (the noGain+OCR sibling — recorded with `shipped: nil`). Which
    /// physical row lands on which call number is not deterministic under concurrency, but the
    /// SUM is: exactly one call is ever "the first", so exactly 7,800 bytes are ever claimed,
    /// whichever row triggered it.
    func testOCROnlyAndRescuedRowsExcludedFromSavedSoFar() async throws {
        let ocr = StubOCREngine(document: recognition())
        let env = try HeavyEnv(ocrEngine: ocr)
        let model = env.model
        model.ocrOn = true
        env.stub.throwOnCall = 2
        env.stub.errorToThrow = CompressError.ghostscriptFailed("gs died")
        env.stub.script = { call, _ in
            switch call {
            case 1:
                return .init(outcome: .compressed(before: 9_000, after: 1_200),
                            shippedBytes: 1_200, runnerUpBytes: nil)
            default:
                return .init(outcome: .noGain(bytes: 9_000), shippedBytes: nil, runnerUpBytes: nil)
            }
        }
        model.add(Array(repeating: env.input, count: 3))
        try await waitUntil(timeout: 10) { model.jobs.count == 3 }

        model.compress()
        try await waitUntil(timeout: 20) { !model.isRunning }

        XCTAssertEqual(model.batchProgress?.savedSoFarBytes, 7_800,
                      "only the genuinely-compressed row contributes; the rescue and the " +
                      "noGain+OCR row are both grey, no-change deliveries")
    }
}
