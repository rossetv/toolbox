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
        let estimate = await estimator.estimate(input, preset: .balanced)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "estimate took \(elapsed)s — real per-file analysis should return promptly")
        XCTAssertGreaterThan(estimate.predictedBytes, 0)
    }

    func testFastAnalysisIsNotFlaggedFallback() async throws {
        let estimator = CompressEstimator(timeBudget: 0.5)
        let input = try Fixtures.bornDigitalPDF()

        let estimate = await estimator.estimate(input, preset: .balanced)

        XCTAssertFalse(estimate.isFallback)
    }

    func testSlowClassifierUsesTheFallbackEstimate() async throws {
        let slow = SlowAnalyser(delay: 2.0)
        let estimator = CompressEstimator(analyser: slow, timeBudget: 0.2)
        let input = try Fixtures.imagePDF()

        let start = Date()
        let estimate = await estimator.estimate(input, preset: .balanced)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "the time box should return well before the injected 2s delay")
        XCTAssertTrue(estimate.isFallback)
        XCTAssertGreaterThan(estimate.predictedBytes, 0)
    }

    func testFailingAnalysisFallsBack() async throws {
        let estimator = CompressEstimator(analyser: FailingAnalyser(), timeBudget: 0.5)
        let input = try Fixtures.imagePDF()

        let estimate = await estimator.estimate(input, preset: .smallestSize)

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
                group.addTask { _ = await estimator.analyse(input) }
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

        let estimate = await estimator.estimate(missing, preset: .balanced)

        XCTAssertTrue(estimate.isFallback)
    }

    /// The recompress prediction (R16) can only tell whether the engine path repeats if it knows
    /// the row's classification, so a successful analysis must surface it alongside the estimates.
    func testAnalysisSurfacesTheContentTypeAlongsideTheEstimates() async throws {
        let estimator = CompressEstimator()
        let input = try Fixtures.bornDigitalPDF()

        let analysis = await estimator.analyse(input)

        XCTAssertEqual(analysis.contentType, .bornDigital)
        XCTAssertEqual(analysis.estimates.count, CompressPreset.allCases.count)
    }

    /// A failed or timed-out analysis has no classification to offer, and says so rather than
    /// guessing — the prediction then falls back to the raw estimate.
    func testAnalysisReportsNoContentTypeWhenAnalysisFails() async throws {
        let estimator = CompressEstimator()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).pdf")

        let analysis = await estimator.analyse(missing)

        XCTAssertNil(analysis.contentType)
        XCTAssertTrue(analysis.estimates[.balanced]?.isFallback == true)
    }
}
