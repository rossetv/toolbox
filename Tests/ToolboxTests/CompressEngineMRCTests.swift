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

    /// Captures the outcome of the single side effect a routing test cares about: whether the MRC
    /// report callback fired (⟺ the hybrid won and was shipped) and, if so, what it carried.
    private final class ReportSpy {
        var fired = false
        var report: MRCDocumentReport?
    }

    /// A stub gs runner that writes a chosen, valid PDF payload to gs's `-sOutputFile=` path — the
    /// gs candidate whose byte count the D7 gate weighs against the real MRC output. Never launches
    /// a process. A copy of the input makes a *large* candidate (MRC beats it); a `tinyValidPDF`
    /// makes a *tiny* one (MRC loses).
    private struct BytesRunner: GhostscriptRunning {
        let bytes: Data
        func run(arguments: [String], readPaths: [URL], writePaths: [URL],
                 onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
            if let path = arguments.first(where: { $0.hasPrefix("-sOutputFile=") })
                .map({ String($0.dropFirst("-sOutputFile=".count)) }) {
                try bytes.write(to: URL(fileURLWithPath: path))
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func makeOutputURLs() throws -> (output: URL, alternate: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrc-routing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.canonical.appendingPathComponent("out.pdf"),
                dir.canonical.appendingPathComponent("runner-up.pdf"))
    }

    /// A genuinely small yet valid PDF that mirrors `input`'s pages: each page rendered at low DPI
    /// and JPEG-encoded, composed through the production `MRCComposer`. Small enough (single-figure
    /// KB) to lose the D7 size gate against a real MRC output, while preserving each page's ink
    /// ratio so it passes `OutputValidator` on the gs delivery path. Page count matches the input.
    private func tinyValidPDF(matching input: URL,
                              maxDimension: CGFloat = 300, quality: Double = 0.4) throws -> Data {
        let service = PDFService()
        let document = try XCTUnwrap(PDFDocument(url: input))
        var pages: [MRCComposer.Page] = []
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let image = try service.render(page, maxDimension: maxDimension)
            let jpeg = try XCTUnwrap(MRCPageEncoder.encodeJPEG(image, quality: quality))
            // Mirror production: the render is upright, so the page uses the displayed size and no `/Rotate`.
            pages.append(MRCComposer.Page(
                content: .jpeg(jpeg),
                size: PDFWriter.displayedSize(mediaBox: page.bounds(for: .mediaBox),
                                              rotation: page.rotation)))
        }
        return try MRCComposer.compose(pages: pages)
    }

    /// The hybrid beats a gs candidate that is itself a valid (smaller-than-input) compression:
    /// shipped output is the MRC hybrid, the gs version is parked in `alternateOutput`, and the
    /// outcome is `.compressedHeavy` carrying the gs bytes as the runner-up (spec R7). gs is
    /// stubbed to the input trimmed by one byte — strictly smaller than the input (R6) while still
    /// larger than the real MRC output — a compressed text scan — which comes in below it.
    func testHybridSmallerThanGsShipsHybridWithRunnerUp() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let inputBytes = try Data(contentsOf: input)
        let gsBytes = inputBytes.dropLast(1)
        let engine = CompressEngine(runner: BytesRunner(bytes: gsBytes))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.fired = true; spy.report = $0 }) { _ in }

        guard case let .compressedHeavy(before, after, runnerUpBytes) = outcome else {
            return XCTFail("expected .compressedHeavy when the hybrid wins, got \(outcome)")
        }
        XCTAssertEqual(before, inputBytes.count, "`before` is the input size")
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

    /// The hybrid loses to a tiny gs candidate: the gs output ships as a plain `.compressed`, no
    /// runner-up file is ever written (R7 — `alternateOutput` untouched). The MRC attempt's report
    /// still fires on this loss path — it is the spec §6 debugging record for the attempt
    /// regardless of the gate outcome. gs is stubbed below the real MRC output's size.
    func testHybridLargerThanGsShipsGsOutput() async throws {
        let input = try Fixtures.colourTextScanPDF(pages: 1)
        let tiny = try tinyValidPDF(matching: input)
        let engine = CompressEngine(runner: BytesRunner(bytes: tiny))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.fired = true; spy.report = $0 }) { _ in }

        guard case let .compressed(_, after) = outcome else {
            return XCTFail("expected a plain .compressed when gs wins, got \(outcome)")
        }
        XCTAssertEqual(after, tiny.count, "the shipped output is the gs candidate")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path),
                       "no runner-up is written when the hybrid loses (R7)")
        XCTAssertTrue(spy.fired, "the report must still fire on a hybrid loss — it's the debugging record")
        XCTAssertEqual(spy.report?.verdicts.count, 1)
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
        let engine = CompressEngine(runner: BytesRunner(bytes: bloated))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { spy.fired = true; spy.report = $0 }) { _ in }

        guard case let .compressedHeavy(before, after, runnerUpBytes) = outcome else {
            return XCTFail("expected .compressedHeavy with the original parked, got \(outcome)")
        }
        XCTAssertEqual(before, inputBytes.count, "`before` is the input size")
        XCTAssertLessThan(after, before, "the hybrid must still be smaller than the input: \(after) vs \(before)")
        XCTAssertEqual(runnerUpBytes, before, "the parked runner-up is the original (its marker)")
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
        let engine = CompressEngine(runner: BytesRunner(bytes: inputBytes))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .maximumQuality, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { _ in spy.fired = true }) { _ in }

        XCTAssertFalse(spy.fired, "maximumQuality must never attempt or ship a hybrid (D3)")
        if case .compressedHeavy = outcome {
            XCTFail("maximumQuality must not ship a hybrid, got \(outcome)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path),
                       "no runner-up when MRC is never attempted")
    }

    /// Regression: a `.scanBilevel` document still routes through Rung 2, not Rung 3. Rung 2 wins
    /// on a clean bilevel scan without ever calling gs, so the runner here fails the test if it is
    /// invoked — proving the document went neither to gs nor to MRC — and the report never fires.
    func testScanBilevelStillRoutesToRungTwo() async throws {
        let engine = CompressEngine(runner: UnusedRunner())
        let input = try Fixtures.greyscaleBilevelScanPDF()
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { _ in spy.fired = true }) { _ in }

        guard case .compressed = outcome else {
            return XCTFail("a bilevel scan must be compressed by Rung 2, got \(outcome)")
        }
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
        let tiny = try tinyValidPDF(matching: input)
        let engine = CompressEngine(runner: BytesRunner(bytes: tiny))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { _ in spy.fired = true }) { _ in }

        guard case .compressed = outcome else {
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
        let engine = CompressEngine(runner: BytesRunner(bytes: inputBytes))
        let (output, alternate) = try makeOutputURLs()
        let spy = ReportSpy()

        let outcome = try await engine.compress(input, preset: .balanced, to: output,
                                                alternateOutput: alternate,
                                                mrcReport: { _ in spy.fired = true }) { _ in }

        guard case let .noGain(bytes) = outcome else {
            return XCTFail("expected .noGain when neither leg beats the input, got \(outcome)")
        }
        XCTAssertEqual(bytes, inputBytes.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "no file on no-gain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path), "no runner-up on no-gain (R7)")
        XCTAssertFalse(spy.fired)
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
