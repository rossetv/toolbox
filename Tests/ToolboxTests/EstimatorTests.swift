// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import Toolbox

/// An analyser that sleeps before returning — exercises the estimator's time-box fallback
/// deterministically, without needing a genuinely pathological input.
private struct SlowAnalyser: PDFAnalysing {
    let delay: TimeInterval
    func pageCount(_ url: URL) throws -> Int {
        Thread.sleep(forTimeInterval: delay)
        return 1
    }
    func classify(_ url: URL) throws -> PDFContentType {
        Thread.sleep(forTimeInterval: delay)
        return .scanColour
    }
}

/// An analyser whose `classify` always throws — exercises the "analysis fails" fallback path
/// distinctly from the "analysis too slow" path.
private struct FailingAnalyser: PDFAnalysing {
    struct Boom: Error {}
    func pageCount(_ url: URL) throws -> Int { 1 }
    func classify(_ url: URL) throws -> PDFContentType { throw Boom() }
}

/// Counts how many analyses are inside `classify` at once, and remembers the peak.
private final class ConcurrencyCounter {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var peak = 0

    func enter() {
        lock.lock()
        inFlight += 1
        peak = max(peak, inFlight)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }
}

/// An analyser that occupies its slot long enough for concurrent callers to overlap.
private struct CountingAnalyser: PDFAnalysing {
    let counter: ConcurrencyCounter
    func pageCount(_ url: URL) throws -> Int { 1 }
    func classify(_ url: URL) throws -> PDFContentType {
        counter.enter()
        defer { counter.leave() }
        Thread.sleep(forTimeInterval: 0.02)
        return .scanColour
    }
}

final class EstimatorTests: XCTestCase {

    func testEstimateReturnsWithinTheTimeBox() async throws {
        let estimator = CompressEstimator(timeBudget: 0.5)
        let input = try Fixtures.imagePDF()

        let start = Date()
        let analysis = await estimator.analyse(input, mrcEligible: true)
        let estimate = try XCTUnwrap(analysis.estimates[.balanced])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "estimate took \(elapsed)s — real per-file analysis should return promptly")
        XCTAssertGreaterThan(estimate.predictedBytes, 0)
    }

    func testFastAnalysisIsNotFlaggedFallback() async throws {
        let estimator = CompressEstimator(timeBudget: 0.5)
        let input = try Fixtures.bornDigitalPDF()

        let analysis = await estimator.analyse(input, mrcEligible: true)
        let estimate = try XCTUnwrap(analysis.estimates[.balanced])

        XCTAssertFalse(estimate.isFallback)
    }

    func testSlowClassifierUsesTheFallbackEstimate() async throws {
        let slow = SlowAnalyser(delay: 2.0)
        let estimator = CompressEstimator(analyser: slow, timeBudget: 0.2)
        let input = try Fixtures.imagePDF()

        let start = Date()
        let analysis = await estimator.analyse(input, mrcEligible: true)
        let estimate = try XCTUnwrap(analysis.estimates[.balanced])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "the time box should return well before the injected 2s delay")
        XCTAssertTrue(estimate.isFallback)
        XCTAssertGreaterThan(estimate.predictedBytes, 0)
    }

    func testFailingAnalysisFallsBack() async throws {
        let estimator = CompressEstimator(analyser: FailingAnalyser(), timeBudget: 0.5)
        let input = try Fixtures.imagePDF()

        let analysis = await estimator.analyse(input, mrcEligible: true)
        let estimate = try XCTUnwrap(analysis.estimates[.smallestSize])

        XCTAssertTrue(estimate.isFallback)
        XCTAssertGreaterThan(estimate.predictedBytes, 0)
    }

    /// One estimate is scheduled per dropped file, and an image-dominated document's analysis holds
    /// a full-page raster while it runs — so the number of concurrent analyses is scaled by the
    /// user's drop and must respect a named bound (§4.4), not GCD's incidental thread ceiling.
    func testConcurrentAnalysesNeverExceedTheNamedBound() async throws {
        let counter = ConcurrencyCounter()
        // A budget far above the injected 20 ms so nothing here times out into the fallback: this
        // test is about how many analyses run at once, not about the time box.
        let estimator = CompressEstimator(analyser: CountingAnalyser(counter: counter), timeBudget: 30)
        let input = try Fixtures.bornDigitalPDF(pages: 1)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<(CompressEstimator.maxConcurrentEstimates * 4) {
                group.addTask { _ = await estimator.analyse(input, mrcEligible: true) }
            }
        }

        XCTAssertGreaterThan(counter.peak, 0, "precondition: the analyses genuinely ran")
        XCTAssertLessThanOrEqual(counter.peak, CompressEstimator.maxConcurrentEstimates,
                                 "\(counter.peak) analyses were in flight at once")
    }

    func testUnreadableInputFallsBackRatherThanCrashing() async throws {
        let estimator = CompressEstimator(timeBudget: 0.5)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")

        let analysis = await estimator.analyse(missing, mrcEligible: true)
        let estimate = try XCTUnwrap(analysis.estimates[.balanced])

        XCTAssertTrue(estimate.isFallback)
    }

    // MARK: the scan-rebuild calibration (spec §6.7)

    /// The calibration's own proof: the `.scanColour` prediction is checked against what the REAL
    /// pipeline delivers on this fixture — bundled Ghostscript, the Rung-3 race and its D7 gate —
    /// never against a recalled figure. The constants were measured this way (F5d); this test is
    /// what stops them drifting away from the engine.
    ///
    /// Tolerance is RELATIVE to the measured reduction, per the calibration record: ±25%, the
    /// plan's recorded fallback. One constant prices two populations that genuinely differ — this
    /// fixture is a raw-bitmap page that Ghostscript alone crushes ~99%, while a real scan's
    /// delivered reduction sits lower — and no single figure sits within ±15% of both.
    func testScanColourPredictionMatchesMRCPipelineOnFixture() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let inputSize = try XCTUnwrap(input.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let engine = CompressEngine(runner: try GhostscriptRunner())
        let output = input.deletingLastPathComponent()
            .appendingPathComponent("calibration-out.pdf")

        let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }

        XCTAssertEqual(outcome.shippedVariant, .mrc,
                       "precondition: this fixture must exercise the REBUILD path, not gs alone")
        let measured = 1 - Double(outcome.finalBytes) / Double(outcome.originalBytes)

        // The production 0.5 s box legitimately overruns under the gate's 8 parallel workers, and
        // a fallback estimate arrives exactly once — so the budget is raised rather than waited on.
        let estimator = CompressEstimator(timeBudget: 30)
        let analysis = await estimator.analyse(input, mrcEligible: true)
        let estimate = try XCTUnwrap(analysis.estimates[.balanced])
        XCTAssertEqual(analysis.contentType, .scanColour,
                       "precondition: the estimator must route this document the way the engine did")
        XCTAssertFalse(estimate.isFallback, "precondition: a fallback estimate prices nothing")

        let predicted = 1 - Double(estimate.predictedBytes) / Double(inputSize)
        XCTAssertEqual(predicted, measured, accuracy: measured * 0.25,
                       "predicted \(predicted) vs measured \(measured) on the real pipeline")
    }

    /// §6.7's honesty rule: a row whose "Rebuild the scan" is off never runs Rung 3, so it must be
    /// priced on the gs-only path it will actually take — and `.maximumQuality`, where the rebuild
    /// never runs at all (MRC D3), must be untouched by the flip.
    func testScanColourWithRebuildOptOutPredictsNonMRCReduction() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let inputSize = try XCTUnwrap(input.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let estimator = CompressEstimator(timeBudget: 30)

        let rebuilt = await estimator.analyse(input, mrcEligible: true)
        let optedOut = await estimator.analyse(input, mrcEligible: false)

        XCTAssertEqual(rebuilt.contentType, .scanColour)
        XCTAssertFalse(try XCTUnwrap(rebuilt.estimates[.balanced]).isFallback)
        XCTAssertFalse(try XCTUnwrap(optedOut.estimates[.balanced]).isFallback)

        for preset in [CompressPreset.balanced, .smallestSize] {
            let withRebuild = try XCTUnwrap(rebuilt.estimates[preset]).predictedBytes
            let without = try XCTUnwrap(optedOut.estimates[preset]).predictedBytes
            XCTAssertGreaterThan(without, withRebuild,
                                 "\(preset): an opted-out row must predict the larger, gs-only result")
        }
        XCTAssertEqual(try XCTUnwrap(optedOut.estimates[.maximumQuality]).predictedBytes,
                       try XCTUnwrap(rebuilt.estimates[.maximumQuality]).predictedBytes,
                       "the rebuild never runs at Maximum quality, so the flip cannot move it")

        // Both predictions share this document's payload ratio, so the tempering cancels in the
        // ratio: what is left is exactly the two tables' balanced entries. Pinned so neither
        // constant can move without this calibration being revisited.
        let reduction = { (bytes: Int) in 1 - Double(bytes) / Double(inputSize) }
        let ratio = reduction(try XCTUnwrap(optedOut.estimates[.balanced]).predictedBytes)
            / reduction(try XCTUnwrap(rebuilt.estimates[.balanced]).predictedBytes)
        XCTAssertEqual(ratio, 0.45 / 0.82, accuracy: 0.01,
                       "the opt-out must price from the incumbent gs-path constant")
    }

    /// The recompress prediction (R16) can only tell whether the engine path repeats if it knows
    /// the row's classification, so a successful analysis must surface it alongside the estimates.
    func testAnalysisSurfacesTheContentTypeAlongsideTheEstimates() async throws {
        let estimator = CompressEstimator()
        let input = try Fixtures.bornDigitalPDF()

        let analysis = await estimator.analyse(input, mrcEligible: true)

        XCTAssertEqual(analysis.contentType, .bornDigital)
        XCTAssertEqual(analysis.estimates.count, CompressPreset.allCases.count)
    }

    /// A failed or timed-out analysis has no classification to offer, and says so rather than
    /// guessing — the prediction then falls back to the raw estimate.
    func testAnalysisReportsNoContentTypeWhenAnalysisFails() async throws {
        let estimator = CompressEstimator()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).pdf")

        let analysis = await estimator.analyse(missing, mrcEligible: true)

        XCTAssertNil(analysis.contentType)
        XCTAssertTrue(analysis.estimates[.balanced]?.isFallback == true)
    }
}
