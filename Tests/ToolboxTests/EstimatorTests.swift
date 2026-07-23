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

    func testUnreadableInputFallsBackRatherThanCrashing() async throws {
        let estimator = CompressEstimator(timeBudget: 0.5)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")

        let estimate = await estimator.estimate(missing, preset: .balanced)

        XCTAssertTrue(estimate.isFallback)
    }
}
