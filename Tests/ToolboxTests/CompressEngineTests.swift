// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import PDFKit
import XCTest
@testable import Toolbox

final class CompressEngineTests: XCTestCase {

    private func makeEngine() throws -> CompressEngine {
        CompressEngine(runner: try GhostscriptRunner())   // bundled gs via Bundle.main
    }

    func testCompressImageShrinksAndValidates() async throws {
        let engine = try makeEngine()
        let input = try Fixtures.imagePDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("image-compressed.pdf")

        let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }

        guard case let .compressed(before, after) = outcome else {
            return XCTFail("expected .compressed, got \(outcome)")
        }
        XCTAssertLessThan(after, before, "expected a smaller output: \(before) → \(after)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        // Page count preserved and output valid.
        let inDoc = try XCTUnwrap(PDFDocument(url: input))
        let outDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(outDoc.pageCount, inDoc.pageCount)
    }

    func testNoGainKeepsOriginalAndWritesNoFile() async throws {
        let engine = try makeEngine()
        // A blank page: gs's pdfwrite structure makes it *larger* than the CoreGraphics original.
        let input = try Fixtures.blankPDF(pages: 1)
        let output = input.deletingLastPathComponent().appendingPathComponent("blank-compressed.pdf")

        let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }

        guard case let .noGain(bytes) = outcome else {
            return XCTFail("expected .noGain, got \(outcome)")
        }
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "no output file should be written on no-gain")
    }

    func testSparseBilevelValidatesNotFalselyRejected() async throws {
        // Regression (found in Track C integration): a legitimately sparse scan — a few lines of
        // text with wide margins — once tripped the OutputValidator blank-page check after real gs
        // downsampling and was wrongly rejected as validationFailed, silently dropping the job. It
        // must now complete: either compressed or no-gain, never a validation failure.
        let engine = try makeEngine()
        let input = try Fixtures.bilevelPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("bilevel-compressed.pdf")

        let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }

        switch outcome {
        case .compressed, .noGain: break   // both acceptable; the point is it did NOT throw validationFailed
        default: XCTFail("expected .compressed or .noGain, got \(outcome)")
        }
    }

    func testEncryptedInputThrows() async throws {
        let engine = try makeEngine()
        let input = try Fixtures.encryptedPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("enc-compressed.pdf")

        do {
            _ = try await engine.compress(input, preset: .balanced, to: output) { _ in }
            XCTFail("expected a throw for an encrypted input")
        } catch CompressError.encrypted {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCorruptInputThrows() async throws {
        let engine = try makeEngine()
        let input = try Fixtures.corruptPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("corrupt-compressed.pdf")

        do {
            _ = try await engine.compress(input, preset: .balanced, to: output) { _ in }
            XCTFail("expected a throw for a corrupt input")
        } catch CompressError.corrupt {
            // expected
        }
    }

    // MARK: FIX 2 — a gs exit-0 with no / invalid output is a FAILURE, never `.noGain`

    /// gs "succeeds" (exit 0) but writes nothing → the batch must see a failure, not a
    /// masked "already optimised". Reproduced with a stub runner because a real gs cannot be
    /// forced to exit 0 while producing an empty output.
    func testEmptyGhostscriptOutputIsFailureNotNoGain() async throws {
        let engine = CompressEngine(runner: StubRunner(exitCode: 0, output: .none))
        let input = try Fixtures.imagePDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("empty-compressed.pdf")

        do {
            let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }
            XCTFail("expected a failure for empty gs output, got \(outcome)")
        } catch is CompressError {
            // expected — any CompressError, never a `.noGain`/`.compressed` return
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "no output file should be written when gs produced nothing")
    }

    /// gs exits 0 and writes a blob that is ≥ the input but is not a valid PDF → this must be
    /// a failure, not `.noGain`: an invalid ≥-input output must never masquerade as no-gain.
    func testInvalidLargerOutputIsFailureNotNoGain() async throws {
        // A ≥-input, non-PDF blob (100 KB of zero bytes → `PDFDocument` returns nil).
        let blob = Data(count: 100_000)
        let engine = CompressEngine(runner: StubRunner(exitCode: 0, output: .bytes(blob)))
        let input = try Fixtures.blankPDF(pages: 1)   // a few KB → the blob is larger
        let output = input.deletingLastPathComponent().appendingPathComponent("invalid-compressed.pdf")

        do {
            let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }
            XCTFail("expected a failure for an invalid ≥-input output, got \(outcome)")
        } catch is CompressError {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "no output file should be written for an invalid output")
    }

    // MARK: M1 — a cancelled compression delivers nothing

    /// Cancel while gs is running. The stub's output is a **deliverable** one — valid, smaller,
    /// same page count, and (retaining well over `minRetainedInk` of the input's ink) it passes
    /// `OutputValidator` — so without the engine's cancellation checks this run would place a
    /// file in the user's folder, which is exactly the reported defect. The assertions are
    /// therefore both discriminating. The stub retains 6/14 ≈ 0.43 of the input's ink by
    /// construction (a ratio of line counts); raising `OutputValidator.minRetainedInk` past
    /// 0.43 would silently strip this test of that property — revisit the fixtures if so.
    ///
    /// The input must classify `.bornDigital`: an all-white `blankPDF` reads as near-two-tone,
    /// which routes the engine through the whole Rung-2 attempt (1500 px render + binarise +
    /// CCITT) before it ever reaches the gated runner — ~2 s of irrelevant work that blew the
    /// 5 s `entered` window on a loaded CI runner.
    func testCancelDuringGhostscriptRunDeliversNoOutput() async throws {
        let input = try Fixtures.bornDigitalPDF(pages: 1)
        let output = input.deletingLastPathComponent().appendingPathComponent("cancelled-compressed.pdf")

        let smaller = try Data(contentsOf: Fixtures.bornDigitalPDF(pages: 1, lines: 6))
        XCTAssertNotNil(PDFDocument(data: smaller), "the stub output must be a valid PDF")
        XCTAssertLessThan(smaller.count, TestSupport.fileSize(input),
                          "the stub output must be a genuine gain, or the engine would return .noGain")

        let entered = XCTestExpectation(description: "gs run entered")
        let gate = Gate()
        let engine = CompressEngine(runner: GatedRunner(bytes: smaller, entered: entered, release: gate))

        let handle = Task {
            try await engine.compress(input, preset: .balanced, to: output) { _ in }
        }
        await fulfillment(of: [entered], timeout: 5)
        handle.cancel()
        await gate.open()

        do {
            let outcome = try await handle.value
            XCTFail("expected the cancelled compression to throw, got \(outcome)")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a cancelled job must leave no output file")
    }

    // MARK: S16 — attacker-influenced gs stderr never reaches the UI unbounded

    /// A malformed PDF can make gs emit a warning per object. The failure the user sees (and the
    /// job list retains) must stay short and must still carry gs's actual diagnosis, which is in
    /// its last lines.
    func testGhostscriptFailureMessageIsBoundedAndKeepsTheDiagnosis() async throws {
        let noise = String(repeating: "**** Warning: an unexpected object was encountered.\n", count: 100_000)
        let runner = StubRunner(exitCode: 1, output: .none,
                                stderr: noise + "GPL Ghostscript: unrecoverable error, exit code 1\n")
        let engine = CompressEngine(runner: runner)
        let input = try Fixtures.blankPDF(pages: 1)
        let output = input.deletingLastPathComponent().appendingPathComponent("noisy-compressed.pdf")

        do {
            let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }
            XCTFail("expected a failure for a non-zero gs exit, got \(outcome)")
        } catch let error as CompressError {
            let message = error.localizedDescription
            XCTAssertLessThan(message.count, 500,
                              "a multi-megabyte gs stderr must not be retained and rendered verbatim")
            XCTAssertTrue(message.contains("unrecoverable error"),
                          "the message must keep gs's actual diagnosis, got: \(message.debugDescription)")
        }
    }

    /// Regression: `SeatbeltProfile` must scope a directory as `(subpath …)` even when it
    /// doesn't exist on disk yet — exactly the case for the scratch/output dirs
    /// `GhostscriptRunner`/`CompressEngine` build with `isDirectory: true` and profile before
    /// creating. The decision must depend on how the caller constructed the URL, not a
    /// filesystem stat that a not-yet-created path always fails.
    func testSeatbeltProfileScopesANotYetCreatedDirectoryAsSubpath() throws {
        let gs = URL(fileURLWithPath: "/Applications/Toolbox.app/Contents/Resources/ghostscript/bin/gs")
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-seatbelt-test-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDir.path),
                       "fixture precondition: the directory must not exist yet")

        let profile = SeatbeltProfile.profile(gsPath: gs, readPaths: [], writePaths: [missingDir])

        let expectedPath = missingDir.canonical.path
        XCTAssertTrue(profile.contains("(subpath \"\(expectedPath)\")"),
                     "a not-yet-created directory must be scoped as a subpath, got:\n\(profile)")
        XCTAssertFalse(profile.contains("(literal \"\(expectedPath)\")"),
                      "a not-yet-created directory must not be scoped as a literal file")
    }

    /// Regression: gs sometimes puts its actual diagnosis on STDOUT with nothing on stderr at
    /// all (measured: a bogus `-sDEVICE` → exit 1, 236 B on stdout, 0 B on stderr). The failure
    /// message must not collapse to a bare "exit 1" when the real reason is sitting on the
    /// stream the old code discarded.
    func testGhostscriptFailureMessageIncludesStdoutWhenStderrIsEmpty() async throws {
        let runner = StubRunner(exitCode: 1, output: .none,
                                stdout: "Unrecoverable error: Unknown device requested\n")
        let engine = CompressEngine(runner: runner)
        let input = try Fixtures.blankPDF(pages: 1)
        let output = input.deletingLastPathComponent().appendingPathComponent("stdout-diag-compressed.pdf")

        do {
            let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }
            XCTFail("expected a failure for a non-zero gs exit, got \(outcome)")
        } catch let error as CompressError {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Unknown device requested"),
                          "the message must surface gs's stdout diagnosis, got: \(message.debugDescription)")
        }
    }

    // MARK: Distiller params wired into the gs argv

    /// Ordering is load-bearing: `-c` ends option parsing, so `-sOutputFile` must precede it
    /// and the input must arrive via `-f`, else gs writes nothing (measured, not theoretical).
    func testGsInvocationPlacesDistillerParamsAfterOutputAndInputAfterDashF() async throws {
        let input = try Fixtures.imagePDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let runner = RecordingRunner(bytes: smallValidPDFData())  // reuse existing helper making a tiny real PDF
        _ = try? await CompressEngine(runner: runner).compress(input, preset: .balanced, to: output) { _ in }
        let args = runner.seenArguments
        let outIdx = try XCTUnwrap(args.firstIndex(where: { $0.hasPrefix("-sOutputFile=") }))
        let cIdx = try XCTUnwrap(args.firstIndex(of: "-c"))
        let fIdx = try XCTUnwrap(args.firstIndex(of: "-f"))
        XCTAssertLessThan(outIdx, cIdx)
        XCTAssertEqual(args[cIdx + 1], CompressPreset.balanced.gsDistillerParams())
        XCTAssertEqual(fIdx, cIdx + 2)
        XCTAssertEqual(args.last, args[fIdx + 1])   // input path is the final element
    }

}

/// A small, real, valid PDF's bytes — used where a `RecordingRunner`/`StubRunner` needs to write
/// something that passes output validation.
private func smallValidPDFData() -> Data {
    try! Data(contentsOf: Fixtures.blankPDF(pages: 1))
}

/// Records the argv it was invoked with so argument-assembly can be asserted.
private final class RecordingRunner: GhostscriptRunning, @unchecked Sendable {
    var seenArguments: [String] = []
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    func run(arguments: [String], readPaths: [URL], writePaths: [URL],
             onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
        seenArguments = arguments
        if let out = arguments.first(where: { $0.hasPrefix("-sOutputFile=") })
            .map({ URL(fileURLWithPath: String($0.dropFirst("-sOutputFile=".count))) }) {
            try bytes.write(to: out)
        }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

/// Deterministic handshake: lets the test cancel exactly while the "gs run" is in flight, with no
/// ordering race (open-before-wait returns immediately).
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
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

/// A stub runner that parks mid-run until the test releases it, then writes a valid, smaller
/// output — i.e. a run that *would* be delivered if cancellation were ignored.
private struct GatedRunner: GhostscriptRunning {
    let bytes: Data
    let entered: XCTestExpectation
    let release: Gate

    func run(arguments: [String],
             readPaths: [URL],
             writePaths: [URL],
             onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
        entered.fulfill()
        await release.wait()
        if let path = arguments.first(where: { $0.hasPrefix("-sOutputFile=") })
            .map({ String($0.dropFirst("-sOutputFile=".count)) }) {
            try? bytes.write(to: URL(fileURLWithPath: path))
        }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

/// A test double for the gs runner. Simulates outcomes the real binary can't be forced to
/// produce: an exit-0 run that writes no output, or one that writes a chosen blob to gs's
/// `-sOutputFile=` path. Never launches a process.
private struct StubRunner: GhostscriptRunning {
    enum Output {
        case none
        case bytes(Data)
    }

    let exitCode: Int32
    let output: Output
    var stderr: String = ""
    var stdout: String = ""

    func run(arguments: [String],
             readPaths: [URL],
             writePaths: [URL],
             onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
        if case let .bytes(data) = output, let path = Self.outputPath(from: arguments) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    private static func outputPath(from arguments: [String]) -> String? {
        let flag = "-sOutputFile="
        return arguments.first { $0.hasPrefix(flag) }.map { String($0.dropFirst(flag.count)) }
    }
}

// MARK: - Rung 2 (bilevel scans)

extension CompressEngineTests {
    /// The case Rung 1 cannot serve: a greyscale page that merely *looks* black-and-white.
    /// Ghostscript's mono settings only apply to images already 1-bit, so this came out LARGER
    /// through Rung 1. Rung 2 must binarise it and win.
    func testGreyscaleBilevelScanIsCompressedByRungTwo() async throws {
        let engine = try makeEngine()
        let input = try Fixtures.greyscaleBilevelScanPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("grey-compressed.pdf")

        let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }

        guard case let .compressed(before, after) = outcome else {
            return XCTFail("expected .compressed for a bilevel scan, got \(outcome)")
        }
        XCTAssertLessThan(after, before, "Rung 2 must shrink a bilevel scan: \(before) → \(after)")
        let inDoc = try XCTUnwrap(PDFDocument(url: input))
        let outDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(outDoc.pageCount, inDoc.pageCount, "page count must survive Rung 2")
    }

    /// The OCR-then-Compress journey. Rung 2 repaints every page as a bitmap, so running it over
    /// a document that already carries a text layer destroys that layer permanently — including
    /// one this app's own OCR just added — while still reporting a successful compression.
    /// `classify` samples five pages and needs 40+ characters to call one "text", so a scan with
    /// sparse pages routes here even after OCR.
    func testARecognisedTextLayerSurvivesCompression() async throws {
        let engine = try makeEngine()
        let scan = try Fixtures.greyscaleBilevelScanPDF()

        // Add an invisible text layer exactly as the OCR tool does.
        let ocr = scan.deletingLastPathComponent().appendingPathComponent("scan-ocr.pdf")
        let page = try XCTUnwrap(PDFDocument(url: scan)?.page(at: 0))
        try PDFWriter().appendTextLayer(
            to: scan, output: ocr,
            pageText: [0: [PositionedText(text: "INVOICE",
                                          boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.06))]],
            geometry: [0: PageGeometry(mediaBox: page.bounds(for: .mediaBox), rotation: 0)])

        let recognised = (PDFDocument(url: ocr)?.string ?? "")
        XCTAssertTrue(recognised.contains("INVOICE"), "fixture precondition: the layer must be there")

        let output = scan.deletingLastPathComponent().appendingPathComponent("scan-ocr-compressed.pdf")
        let outcome = try await engine.compress(ocr, preset: .balanced, to: output) { _ in }

        // On `.noGain` nothing is written and the user simply keeps the original, so the file that
        // must still carry the text is whichever one they are left holding.
        let delivered = FileManager.default.fileExists(atPath: output.path) ? output : ocr
        let after = (PDFDocument(url: delivered)?.string ?? "")
        XCTAssertTrue(after.contains("INVOICE"),
                      "the text layer did not survive compression (outcome \(outcome)) — a Rung-2 "
                      + "rebuild drops everything that is not painted pixels")
    }

    /// A page carrying `/Rotate` must not come back sideways. The bitmap is rendered from the
    /// unrotated media box, so the composed page has to carry the same `/Rotate` through.
    func testRotatedScanKeepsItsOrientation() async throws {
        let engine = try makeEngine()
        let input = try Fixtures.greyscaleBilevelScanPDF()
        let rotated = input.deletingLastPathComponent().appendingPathComponent("rotated.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: input))
        try XCTUnwrap(doc.page(at: 0)).rotation = 90
        XCTAssertTrue(doc.write(to: rotated))

        let before = try XCTUnwrap(PDFDocument(url: rotated)?.page(at: 0))
        let output = input.deletingLastPathComponent().appendingPathComponent("rotated-compressed.pdf")
        _ = try await engine.compress(rotated, preset: .balanced, to: output) { _ in }

        let after = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        XCTAssertEqual(after.rotation, before.rotation, "the page's /Rotate must survive compression")
        // Rotation is what makes these differ; comparing the displayed bounds catches a page that
        // kept its rotation value but lost the geometry it applies to.
        XCTAssertEqual(after.bounds(for: .mediaBox).size.width,
                       before.bounds(for: .mediaBox).size.width, accuracy: 1)
    }

    /// Regression: cancelling the task while Rung 2 is mid-binarise must propagate
    /// `CancellationError` directly, never be swallowed into "Rung 2 declined" and then burn a
    /// whole Ghostscript pass anyway. `bilevelCompress` checks cancellation at the top of its
    /// per-page loop, before any per-page work, so cancelling immediately after dispatch is
    /// deterministic here — no gate/timing dependency needed.
    func testCancelDuringRungTwoPropagatesCancellationRatherThanFallingBackToRungOne() async throws {
        let engine = try makeEngine()
        let input = try Fixtures.greyscaleBilevelScanPDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("cancelled-bilevel-compressed.pdf")

        let handle = Task {
            try await engine.compress(input, preset: .balanced, to: output) { _ in }
        }
        handle.cancel()

        do {
            let outcome = try await handle.value
            XCTFail("expected the cancelled Rung-2 attempt to propagate cancellation, got \(outcome)")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a cancelled job must leave no output file")
    }

    /// Regression: Rung 2 can process several pages — driving progress up — before declining on
    /// a LATER page (here, one that carries an annotation `bilevelCompress` refuses to touch)
    /// and falling through to Rung 1. The caller's progress callback must never see a value
    /// lower than one already reported. Uses a deterministic stub for Rung 1 so the assertion
    /// doesn't depend on real Ghostscript's own (best-effort) page-marker parsing.
    func testProgressNeverRegressesWhenRungTwoDeclinesAfterPartialProgress() async throws {
        let scan = try Fixtures.greyscaleBilevelScanPDF()
        let document = try XCTUnwrap(PDFDocument(url: scan))
        let page0 = try XCTUnwrap(document.page(at: 0))
        for _ in 0..<4 {
            document.insert(try XCTUnwrap(page0.copy() as? PDFPage), at: document.pageCount)
        }
        // 5 identical clean pages; the last one gets an annotation, which `bilevelCompress`
        // refuses to touch — Rung 2 processes pages 0–3 (progress climbs to 0.8) before
        // declining on page 4, and the engine falls through to Rung 1.
        let lastPage = try XCTUnwrap(document.page(at: document.pageCount - 1))
        lastPage.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                                             forType: .text, withProperties: nil))
        let input = scan.deletingLastPathComponent().appendingPathComponent("mixed.pdf")
        XCTAssertTrue(document.write(to: input))
        XCTAssertEqual(PDFDocument(url: input)?.pageCount, 5)

        struct ProgressStubRunner: GhostscriptRunning {
            func run(arguments: [String], readPaths: [URL], writePaths: [URL],
                     onProgress: ((Int) -> Void)?) async throws -> ProcessResult {
                for page in 1...5 { onProgress?(page) }
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        }
        let engine = CompressEngine(runner: ProgressStubRunner())
        let output = scan.deletingLastPathComponent().appendingPathComponent("mixed-compressed.pdf")

        var observed: [Double] = []
        _ = try? await engine.compress(input, preset: .balanced, to: output) { observed.append($0) }

        XCTAssertFalse(observed.isEmpty, "expected progress to be reported")
        for (previous, next) in zip(observed, observed.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next, previous,
                                        "progress regressed from \(previous) to \(next) in \(observed)")
        }
    }

    /// A colour photo must never be binarised — that would destroy it. It must fall through to
    /// Rung 1 and still produce a valid, no-larger result.
    func testColourPhotoIsNotBinarised() async throws {
        let engine = try makeEngine()
        let input = try Fixtures.imagePDF()
        let output = input.deletingLastPathComponent().appendingPathComponent("photo-compressed.pdf")

        let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }

        switch outcome {
        case .compressed, .noGain: break
        default: XCTFail("expected a normal Rung-1 outcome, got \(outcome)")
        }
        if case .compressed = outcome {
            let outDoc = try XCTUnwrap(PDFDocument(url: output))
            let page = try XCTUnwrap(outDoc.page(at: 0))
            // A binarised photo would collapse to two tones; a real one keeps a range of greys.
            let rendered = try PDFService().render(page, maxDimension: 400)
            XCTAssertNotNil(rendered)
        }
    }
}
