// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import PDFKit
import XCTest
@testable import Toolbox

/// Rung-3 (`mrcCompress`) per-page driver. The driver never touches Ghostscript, so these tests
/// call it directly with a no-op runner. It is reached directly rather than through `compress`
/// because the routing/D7 gate (Task 15) is not yet wired — until then `compress` ignores the MRC
/// parameters and these tests are the only entry point.
final class CompressEngineMRCTests: XCTestCase {

    /// The driver needs no gs; this runner exists only to satisfy the `CompressEngine`
    /// initialiser and must never be invoked.
    private struct UnusedRunner: GhostscriptRunning {
        func run(arguments: [String], readPaths: [URL], writePaths: [URL],
                 onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
            XCTFail("mrcCompress must never call Ghostscript")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
    }

    private func makeEngine() -> CompressEngine { CompressEngine(runner: UnusedRunner()) }

    private func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrc-driver-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.canonical
    }

    /// Mixed fixture, real classifier: the text page is MRC-encoded, the photo page falls outside
    /// the eligibility envelope and ships its JPEG fallback — both recorded, document composes.
    func testMixedDocumentEncodesTextPageAndFallsBackPhotoPage() async throws {
        let engine = makeEngine()
        let input = try Fixtures.mixedColourScanPDF()
        let work = try makeWorkDir()

        let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

        let unwrapped = try XCTUnwrap(result, "a mixed document with one MRC page must compose")
        XCTAssertEqual(unwrapped.report.verdicts.count, 2, "every page must be recorded")
        guard case .mrcEncoded = unwrapped.report.verdicts[0] else {
            return XCTFail("the text page must be MRC-encoded, got \(unwrapped.report.verdicts[0])")
        }
        guard case .fallback = unwrapped.report.verdicts[1] else {
            return XCTFail("the photo page must fall back, got \(unwrapped.report.verdicts[1])")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrapped.url.path))
        XCTAssertGreaterThan(unwrapped.bytes, 0)
        XCTAssertNotNil(PDFDocument(url: unwrapped.url), "the composed hybrid must be a valid PDF")
    }

    /// Verify-before-compose (D6), THE smear regression (spec §9). Both pages are forced past the
    /// classifier; the verifier is overridden to fail the **second** page (the photo pushed through
    /// MRC via `forceEligible`). That page must ship its JPEG fallback while the first still ships
    /// MRC — the swap happens before composition, so no smeared page ever reaches the output.
    func testVerifierRejectionSwapsPageBeforeComposition() async throws {
        let engine = makeEngine()
        let input = try Fixtures.mixedColourScanPDF()
        let work = try makeWorkDir()

        // A reference counter, not a captured `var`, so the non-escaping override is safe to call
        // from the async driver. The verifier is scored once per attempted page, in page order.
        final class Counter { var n = 0 }
        let counter = Counter()
        let failSecond: (MRCVerifier.Score) -> MRCVerifier.Score = { score in
            counter.n += 1
            return counter.n == 2 ? MRCVerifier.Score(normalisedError: 5, pass: false) : score
        }

        let result = try await engine.mrcCompress(input, preset: .balanced, to: work,
                                                   forceEligible: true,
                                                   verifierOverride: failSecond) { _ in }

        let unwrapped = try XCTUnwrap(result, "the document must still compose around the swapped page")
        XCTAssertEqual(unwrapped.report.verdicts.count, 2)
        guard case .mrcEncoded = unwrapped.report.verdicts[0] else {
            return XCTFail("the passing page must be MRC-encoded, got \(unwrapped.report.verdicts[0])")
        }
        guard case .fallback(.verifierRejected) = unwrapped.report.verdicts[1] else {
            return XCTFail("the rejected page must fall back as verifierRejected, got "
                           + "\(unwrapped.report.verdicts[1])")
        }
        XCTAssertNotNil(PDFDocument(url: unwrapped.url))
    }

    /// A document over `maxMRCPages` declines whole-document (nil) before any per-page work — no
    /// partial output is written.
    func testPageCapDeclines() async throws {
        let engine = makeEngine()
        let input = try Fixtures.blankPDF(pages: CompressEngine.maxMRCPages + 1)
        let work = try makeWorkDir()

        let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

        XCTAssertNil(result, "a document past the page cap must decline")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("mrc.pdf").path),
            "an over-cap decline must not write partial work")
    }

    /// One complex page (born-digital vector text appended to an otherwise-eligible scan) fails the
    /// structural sweep, so the whole document declines (R2) rather than rasterising the text page.
    func testComplexPageDisqualifiesDocument() async throws {
        let engine = makeEngine()
        let scan = try Fixtures.colourTextScanPDF(pages: 1)
        let born = try Fixtures.bornDigitalPDF(pages: 1)

        let document = try XCTUnwrap(PDFDocument(url: scan))
        let bornPage = try XCTUnwrap(PDFDocument(url: born)?.page(at: 0))
        document.insert(try XCTUnwrap(bornPage.copy() as? PDFPage), at: document.pageCount)
        let input = scan.deletingLastPathComponent().appendingPathComponent("scan-plus-text.pdf")
        XCTAssertTrue(document.write(to: input))
        XCTAssertEqual(PDFDocument(url: input)?.pageCount, 2, "fixture precondition")

        let work = try makeWorkDir()
        let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

        XCTAssertNil(result, "a document carrying a complex page must decline whole-document")
    }

    /// Cancellation mid-page-loop rethrows `CancellationError`, never a silent decline. The
    /// structural sweep checks cancellation at the top of its loop before any per-page work, so
    /// cancelling immediately after dispatch is deterministic.
    func testCancellationRethrows() async throws {
        let engine = makeEngine()
        let input = try Fixtures.colourTextScanPDF(pages: 2)
        let work = try makeWorkDir()

        let handle = Task {
            try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }
        }
        handle.cancel()

        do {
            let result = try await handle.value
            XCTFail("expected the cancelled driver to rethrow, got \(String(describing: result))")
        } catch is CancellationError {
            // expected
        }
    }

    /// Regression: an oversized page whose render clamps below 150 dpi must decline the whole
    /// document (return nil), not ship a degraded rebuild. The effective-DPI floor guard (R13,
    /// `minBilevelDPI`) must be present and enforced, mirroring the Rung-2 guard in
    /// `bilevelCompress`.
    func testOversizedPageBelowMinDPIDeclines() async throws {
        let engine = makeEngine()
        let input = try Fixtures.oversizedPageScanPDF()
        let work = try makeWorkDir()

        let result = try await engine.mrcCompress(input, preset: .balanced, to: work) { _ in }

        XCTAssertNil(result, "a page clamping below 150 dpi must decline the whole document")
    }
}

// MARK: - Routing, the D7 document gate and runner-up delivery (through `compress`)

/// Task 15: the whole-`compress` behaviour behind the MRC parameters — content routing to Rung 3,
/// the D7 winner gate, and the runner-up cache copy. The gs leg is stubbed (`BytesRunner`) so the
/// gs candidate's size is deterministic; the MRC leg runs for real (it never touches Ghostscript),
/// so the two competing sizes are one measured value and one fixed value, never a race.
final class CompressEngineRoutingTests: XCTestCase {

    /// Captures the side effect a routing test cares about: whether the MRC report callback fired
    /// (⟺ a hybrid was actually built and weighed) and what it carried. A COUNT, not a flag: the
    /// report has two firing sites — the winner's delivery and the loss path — and "fired exactly
    /// once" is the invariant a flag would hide.
    private final class ReportSpy {
        private(set) var count = 0
        private(set) var report: MRCDocumentReport?
        var fired: Bool { count > 0 }

        func record(_ report: MRCDocumentReport) {
            count += 1
            self.report = report
        }
    }

    // The gs stub (`TestSupport.BytesRunner`) and the small-valid-PDF builder
    // (`TestSupport.tinyValidPDF`) are shared with the Rung-2 size-race tests — see TestSupport.

    private func makeOutputURLs() throws -> (output: URL, alternate: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrc-routing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.canonical.appendingPathComponent("out.pdf"),
                dir.canonical.appendingPathComponent("runner-up.pdf"))
    }

    private func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrc-routing-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.canonical
    }

    /// A verifier that passes every page. Paired with `forceEligible` — `CompressEngine`'s other
    /// documented test-only seam — it keeps a document on the MRC path that the classifier envelope
    /// or the smear gate would otherwise decline, so a test about a variant's SIZE or VALIDITY
    /// cannot quietly degrade into a test about eligibility.
    private static let passingVerifier: @Sendable (MRCVerifier.Score) -> MRCVerifier.Score = { _ in
        MRCVerifier.Score(normalisedError: 0, pass: true)
    }

    /// The hybrid beats a gs candidate that is itself a valid (smaller-than-input) compression:
    /// shipped output is the MRC hybrid, the gs version is parked in `alternateOutput`, and the
    /// outcome ships `.mrc` with a runner-up descriptor carrying the gs bytes (spec R7). gs is
    /// stubbed to the input trimmed by one byte — strictly smaller than the input (R6) while still
    /// larger than the real MRC output — a compressed text scan — which comes in below it.
    func testHybridSmallerThanGsShipsHybridWithRunnerUp() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let inputBytes = try Data(contentsOf: input)
        let gsBytes = inputBytes.dropLast(1)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: gsBytes))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case let .compressed(before, after) = outcome.compress,
              outcome.shippedVariant == .mrc,
              let retained = outcome.runnerUp else {
            return XCTFail("expected an MRC winner with a retained runner-up, got \(outcome)")
        }
        let runnerUpBytes = retained.bytes
        XCTAssertEqual(before, inputBytes.count, "`before` is the input size")
        XCTAssertEqual(retained.kind, .plain, "the PARKED variant is the gs output, not the winner")
        XCTAssertEqual(runnerUpBytes, gsBytes.count, "the runner-up is the gs candidate")
        XCTAssertLessThan(after, before, "the hybrid must be smaller than the input: \(after) vs \(before)")

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "the hybrid must be shipped")
        XCTAssertEqual(TestSupport.fileSize(output), after, "the shipped file is the hybrid (its bytes)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alternate.path),
                      "the gs version must be parked as the runner-up")
        XCTAssertEqual(TestSupport.fileSize(alternate), runnerUpBytes,
                       "the runner-up file holds the gs bytes")

        XCTAssertTrue(spy.fired, "the MRC report must fire when the hybrid ships")
        XCTAssertEqual(spy.report?.verdicts.count, 1)
        if case .mrcEncoded = spy.report?.verdicts.first {} else {
            XCTFail("the single text page must be MRC-encoded, got \(String(describing: spy.report?.verdicts.first))")
        }
    }

    /// **The R7-asymmetry reversal** (spec §5's change table; supersedes the old
    /// `testHybridLargerThanGsShipsGsOutput`, which asserted that a losing hybrid was discarded).
    /// The hybrid loses to a tiny gs candidate, so gs ships — and the LOSING HYBRID is now retained
    /// as the runner-up, exactly as the losing gs output is when the hybrid wins. Which variant won
    /// the gate decides only what SHIPS; retention is symmetric, because the consent sheet is about
    /// the look of the page, not only its bytes. The attempt's report still fires on this path — it
    /// is the spec §6 debugging record — and exactly once.
    func testHybridLostGateStillWritesRunnerUp() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let tiny = try TestSupport.tinyValidPDF(matching: input)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: tiny))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case let .compressed(before, after) = outcome.compress,
              let retained = outcome.runnerUp else {
            return XCTFail("expected a gs winner with the losing hybrid retained, got \(outcome)")
        }
        XCTAssertEqual(after, tiny.count, "the shipped output is the gs candidate")
        XCTAssertEqual(outcome.shippedVariant, .plain, "gs won the gate, so the plain variant shipped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(TestSupport.fileSize(output), after, "the shipped file is the gs candidate")

        XCTAssertEqual(retained.kind, .mrc, "the PARKED variant is the hybrid, not the winner")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alternate.path),
                      "the losing hybrid must be parked as the runner-up (spec §5's R7 reversal)")
        XCTAssertEqual(TestSupport.fileSize(alternate), retained.bytes,
                       "the runner-up file holds the hybrid's own bytes")
        XCTAssertGreaterThan(retained.bytes, after, "the retained hybrid is the one that LOST on size")
        XCTAssertLessThan(retained.bytes, before,
                          "a retained variant is always smaller than the input (spec §6.3)")

        XCTAssertEqual(spy.count, 1, "the report fires exactly once, on the loss path")
        XCTAssertEqual(spy.report?.verdicts.count, 1)
    }

    /// The other half of the retention gate: a hybrid that loses AND fails validation is retained by
    /// nothing — no file, no descriptor. Validation runs on the loser in the fall-through branch (it
    /// is never hoisted above the size gate — that would cost every MRC document a page-render pass),
    /// and this is what proves it runs at all. The fixture's second page is 5 pt across, so the
    /// rebuild's ~20 px raster genuinely loses its content and the REAL `OutputValidator` rejects the
    /// composed hybrid; the preconditions below pin both facts the assertion depends on — the hybrid
    /// is BUILT and is smaller than the input (so the withhold rule is not what stops it), and it is
    /// invalid.
    func testInvalidHybridLostGateWritesNoRunnerUp() async throws {
        let input = try Fixtures.microPageColourScanPDF()
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: try TestSupport.tinyValidPDF(matching: input)),
                                    forceEligible: true, verifierOverride: Self.passingVerifier)
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let composed = try await engine.mrcCompress(input, preset: .balanced, to: try makeWorkDir(),
                                                    forceEligible: true,
                                                    verifierOverride: Self.passingVerifier) { _ in }
        let probe = try XCTUnwrap(composed, "precondition: this document must compose a hybrid at all")
        XCTAssertLessThan(probe.bytes, TestSupport.fileSize(input),
                          "precondition: the hybrid is smaller than the input, so only validation can stop it")
        XCTAssertFalse(try OutputValidator().validate(input: input, output: probe.url, samplePages: 3),
                       "precondition: the composed hybrid must be one the validator rejects")

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case .compressed = outcome.compress else {
            return XCTFail("expected the gs candidate to ship, got \(outcome)")
        }
        XCTAssertEqual(spy.count, 1, "a hybrid was built and lost — the report is its record")
        XCTAssertNil(outcome.runnerUp, "an invalid variant is never offered as a version to switch to")
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path),
                       "an invalid hybrid must leave no runner-up file behind")
    }

    /// Spec §6.3's withhold rule: a would-be runner-up that is a COMPRESS variant ≥ the input is
    /// withheld — no file, no descriptor — because a card advertising a version bigger than what the
    /// user already has is a regression, whichever way they switch. (The untouched-original park is
    /// NOT a compress artefact and is retained; that is the sibling test above.)
    ///
    /// The fixture's pages share one image XObject, so the input stays flat while the rebuild pays
    /// its cost per page — the only dependable way to make a real hybrid exceed its own input. The
    /// gs candidate is tiny and valid, so the delivery reaches the retention site; the report firing
    /// exactly once is what proves a hybrid was genuinely built and weighed, so a future fixture
    /// change that stopped producing one could not turn this into a vacuous pass.
    func testRunnerUpAtOrAboveInputWithheld() async throws {
        let input = try Fixtures.sharedImageColourScanPDF(pages: 3)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: try TestSupport.tinyValidPDF(matching: input)),
                                    forceEligible: true, verifierOverride: Self.passingVerifier)
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case .compressed = outcome.compress else {
            return XCTFail("expected the gs candidate to ship, got \(outcome)")
        }
        XCTAssertEqual(spy.count, 1, "a hybrid was built and lost — the report is its record")
        XCTAssertNil(outcome.runnerUp,
                     "a compress variant ≥ the input is withheld, never offered (spec §6.3)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path),
                       "a withheld variant must leave no runner-up file behind")
    }

    /// Per-file opt-out (spec §7): `rebuildScan: false` skips the MRC leg on a document that would
    /// otherwise take it and win. The gs candidate is the one from
    /// `testHybridSmallerThanGsShipsHybridWithRunnerUp` — a byte under the input, which that test
    /// proves the hybrid beats — so a report that never fires is proof the leg was never attempted
    /// rather than proof it lost.
    func testRebuildScanFalseSkipsMRCOnScanColour() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let inputBytes = try Data(contentsOf: input)
        let gsBytes = inputBytes.dropLast(1)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: gsBytes))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate, rebuildScan: false,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case let .compressed(_, after) = outcome.compress else {
            return XCTFail("expected the gs output to ship, got \(outcome)")
        }
        XCTAssertEqual(spy.count, 0, "opting out must not attempt the hybrid at all")
        XCTAssertEqual(after, gsBytes.count, "the shipped output is the gs candidate")
        XCTAssertEqual(outcome.shippedVariant, .plain)
        XCTAssertNil(outcome.runnerUp, "nothing was rebuilt, so there is nothing to park")
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path))
    }

    /// Per-file opt-IN never overrides eligibility (spec §7, MRC R2): `rebuildScan: true` on a
    /// born-digital document must not push it through the rebuild — the toggle can only narrow the
    /// engine's own decision, never widen it past the classification that protects text and vector
    /// content from being rasterised.
    func testRebuildScanTrueDoesNotForceIneligible() async throws {
        let input = try Fixtures.bornDigitalPDF(pages: 1)
        XCTAssertNotEqual(try PDFService().classify(input), .scanColour,
                          "precondition: this document is not MRC-eligible by classification")
        let gsBytes = try TestSupport.tinyValidPDF(matching: input)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: gsBytes))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate, rebuildScan: true,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case let .compressed(_, after) = outcome.compress else {
            return XCTFail("expected a plain Rung-1 delivery, got \(outcome)")
        }
        XCTAssertEqual(spy.count, 0, "opting in must never reach the hybrid on an ineligible document")
        XCTAssertEqual(after, gsBytes.count, "the shipped output is the gs candidate")
        XCTAssertEqual(outcome.shippedVariant, .plain)
        XCTAssertNil(outcome.runnerUp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path))
    }

    /// D3 survives the override (spec §7): `rebuildScan: true` at `.maximumQuality` still never
    /// rebuilds. The gs candidate is a byte under the input — the stub the hybrid is proven to beat
    /// — so this fails loudly if the preset guard ever moves below the override.
    func testRebuildScanIgnoredAtMaximumQuality() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let inputBytes = try Data(contentsOf: input)
        let gsBytes = inputBytes.dropLast(1)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: gsBytes))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .maximumQuality, to: output,
                                                alternateOutput: alternate, rebuildScan: true,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case let .compressed(_, after) = outcome.compress else {
            return XCTFail("expected the gs output to ship, got \(outcome)")
        }
        XCTAssertEqual(spy.count, 0, "maximumQuality must never attempt a hybrid, opt-in or not (D3)")
        XCTAssertEqual(after, gsBytes.count)
        XCTAssertEqual(outcome.shippedVariant, .plain)
        XCTAssertNil(outcome.runnerUp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path))
    }

    /// R6/R7: the hybrid beats gs, but gs's own candidate is *not* itself smaller than the input
    /// (it bloated) — nothing legitimate to switch to on the gs side, so the UNTOUCHED ORIGINAL is
    /// parked as the runner-up instead (`runnerUpBytes == before` marks it) and the row still gets
    /// its capsule: R7 demands every MRC-shipped document retain a version to switch to, and R6
    /// forbids that version being a larger-than-input gs output.
    func testHybridWinsButGsCandidateNotSmallerThanInputParksOriginalAsRunnerUp() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let inputBytes = try Data(contentsOf: input)
        let bloated = inputBytes + Data(repeating: 0, count: 4096)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: bloated))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case let .compressed(before, after) = outcome.compress,
              outcome.shippedVariant == .mrc,
              let retained = outcome.runnerUp else {
            return XCTFail("expected an MRC winner with the original parked, got \(outcome)")
        }
        XCTAssertEqual(before, inputBytes.count, "`before` is the input size")
        XCTAssertLessThan(after, before, "the hybrid must still be smaller than the input: \(after) vs \(before)")
        XCTAssertEqual(retained.kind, .original, "gs bloated, so the untouched input is what is parked")
        XCTAssertEqual(retained.bytes, before, "the parked runner-up is the original (its marker)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "the hybrid must still be shipped")
        XCTAssertEqual(TestSupport.fileSize(output), after, "the shipped file is the hybrid (its bytes)")
        XCTAssertEqual(try Data(contentsOf: alternate), inputBytes,
                       "the runner-up file is a byte-identical copy of the input (never the bloated gs output)")
        XCTAssertTrue(spy.fired, "the MRC report must still fire — the hybrid did win")
    }

    /// D3: at `.maximumQuality` a `.scanColour` document must never attempt the MRC hybrid. gs is a
    /// copy of the input, so *if* the preset guard were broken the hybrid would win and the report
    /// would fire — this test is discriminating precisely because that never happens.
    func testScanColourOnMaximumQualityNeverAttemptsMRC() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let inputBytes = try Data(contentsOf: input)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: inputBytes))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .maximumQuality, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.record($0) }) { _ in }

        XCTAssertFalse(spy.fired, "maximumQuality must never attempt or ship a hybrid (D3)")
        XCTAssertNotEqual(outcome.shippedVariant, .mrc,
                          "maximumQuality must not ship a hybrid, got \(outcome)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path),
                       "no runner-up when MRC is never attempted")
    }

    /// Regression: a `.scanBilevel` document still routes through Rung 2, not Rung 3. Under the
    /// size race gs always produces a candidate, so it is stubbed to a no-gain copy of the input —
    /// the CCITT output shipping strictly smaller proves Rung 2 both ran and won the race, and the
    /// report never fires because MRC was never attempted.
    func testScanBilevelStillRoutesToRungTwo() async throws {
        let input = try Fixtures.greyscaleBilevelScanPDF()
        let inputBytes = try Data(contentsOf: input)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: inputBytes))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case let .compressed(before, after) = outcome.compress else {
            return XCTFail("a bilevel scan must be compressed by Rung 2, got \(outcome)")
        }
        XCTAssertEqual(before, inputBytes.count, "`before` is the input size")
        XCTAssertLessThan(after, before,
                          "the shipped output must be the CCITT candidate, strictly smaller than the no-gain gs stub")
        XCTAssertEqual(TestSupport.fileSize(output), after, "the shipped file is the CCITT output")
        XCTAssertFalse(spy.fired, "a Rung-2 document must never touch the MRC report")
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path),
                       "Rung 2 never writes a runner-up")
    }

    /// D10: when the MRC leg declines (here a photo-only scan whose every page falls outside the
    /// classifier envelope, so `mrcCompress` returns nil), the document ships as the gs output with
    /// no throw, no runner-up and no report. The routing catch's swallow-non-cancellation branch is
    /// byte-identical to the Rung-2 `bilevelCompress` call site; this exercises the decline path.
    func testMRCInternalFailureShipsGsSilently() async throws {
        let input = try Fixtures.colourPhotoScanPDF(pages: 1)
        let tiny = try TestSupport.tinyValidPDF(matching: input)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: tiny))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case .compressed = outcome.compress else {
            return XCTFail("an MRC decline must ship the gs output, got \(outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path),
                       "no runner-up when the hybrid never wins (R7)")
        XCTAssertFalse(spy.fired)
    }

    /// The never-larger-than-input guard survives routing: a `.scanColour` photo whose MRC leg
    /// declines, with gs stubbed to a copy of the input (no gain), must return `.noGain`, write no
    /// output and write no runner-up.
    func testNeverLargerThanInputStillHolds() async throws {
        let input = try Fixtures.colourPhotoScanPDF(pages: 1)
        let inputBytes = try Data(contentsOf: input)
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: inputBytes))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.record($0) }) { _ in }

        guard case let .noGain(bytes) = outcome.compress else {
            return XCTFail("expected a no-gain leg when neither beats the input, got \(outcome)")
        }
        XCTAssertEqual(bytes, inputBytes.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "no file on no-gain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path), "no runner-up on no-gain (R7)")
        XCTAssertFalse(spy.fired)
    }

    /// Mutable state shared with the cancelled job's callbacks. A class rather than a captured
    /// `var` because the progress callback runs inside the `Task` under test.
    private final class CancelHook: @unchecked Sendable {
        var task: Task<RowOutcome, Error>?
        var reachedRungThree = false
    }

    /// §3.2 on the Rung-3 delivery path — "a failed or cancelled job leaves nothing behind".
    /// `CompressEngineTests.testCancelDuringRungTwoPropagatesCancellationRatherThanFallingBackToRungOne`
    /// asserts this for Rung 2; its Rung-3 sibling `testCancellationRethrows` asserts only the
    /// rethrow, and it drives `mrcCompress` directly — which stages into a work dir and has no
    /// `output`, no `alternateOutput` and no staging temp to assert on. So the delivery invariant
    /// needs the whole `compress`, which is what this drives.
    ///
    /// The job cancels itself from its own progress callback rather than at dispatch: gs is capped
    /// at 0.45 for an MRC-routed document and the hybrid leg maps into 0.45…0.95, so a tick at 0.95
    /// is proof the Rung-3 leg ran — cancelling at dispatch would throw at the post-gs check and
    /// never reach Rung 3 at all. `reachedRungThree` asserts that, so the test cannot quietly
    /// degrade into the earlier check's coverage.
    ///
    /// What this deliberately does NOT pin: the two `Task.checkCancellation()` calls inside the
    /// winner block itself. A cancelled `OutputValidator.validate` throws, and the D7 gate calls it
    /// through `try?`, so the cancellation is read as "the hybrid failed to validate" and surfaces
    /// one step later from the gs delivery's own validate. There is no caller-visible hook between
    /// the D7 gate and the rename, so landing a cancel strictly inside that window would take a
    /// wall-clock guess — a flaky red, not a proof. Stated rather than manufactured. The staging
    /// assertion below is therefore defence-in-depth rather than a currently-reachable invariant:
    /// on the path this test takes the throw arrives before any `.toolbox-*` temp is created, and
    /// the assertion only goes live if someone loosens `validate`'s cancellation check AND drops
    /// the winner block's own checks. Kept because that pair is exactly what would regress here.
    func testCancelDuringRungThreeDeliversNoOutput() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let inputBytes = try Data(contentsOf: input)
        // The same stub as the winning-hybrid test: a gs candidate one byte under the input, so the
        // hybrid is on course to win the D7 race and reach the delivery block being guarded.
        let engine = CompressEngine(runner: TestSupport.BytesRunner(bytes: inputBytes.dropLast(1)))
        let (output, alternate) = try makeOutputURLs()

        let hook = CancelHook()
        hook.task = Task {
            try await engine.compress(input, preset: .balanced, to: output,
                                      alternateOutput: alternate) { fraction in
                if fraction >= 0.9 {
                    hook.reachedRungThree = true
                    hook.task?.cancel()
                }
            }
        }

        do {
            let outcome = try await XCTUnwrap(hook.task).value
            XCTFail("expected the cancelled Rung-3 job to propagate cancellation, got \(outcome)")
        } catch is CancellationError {
            // expected
        }

        XCTAssertTrue(hook.reachedRungThree,
                      "the cancel must land on the Rung-3 leg — otherwise this only re-tests the post-gs check")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a cancelled job must leave no output file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path),
                       "a cancelled job must leave no runner-up remnant either")
        let staging = try FileManager.default
            .contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".toolbox-") }
        XCTAssertTrue(staging.isEmpty,
                      "a cancelled job must leave no staging temp in the destination: \(staging)")
    }

    /// The driver needs no gs; this runner exists only to satisfy the initialiser and fails the
    /// test if the document is ever routed to Ghostscript.
    private struct UnusedRunner: GhostscriptRunning {
        func run(arguments: [String], readPaths: [URL], writePaths: [URL],
                 onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
            XCTFail("this document must not be routed to Ghostscript")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }
    }
}
