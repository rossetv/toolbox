// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import PDFKit
import XCTest
@testable import Toolbox

final class SeatbeltRunTests: XCTestCase {

    // MARK: profile string shape

    func testProfileContainsRequiredClauses() {
        // Any gs URL works for string-shape assertions (no launch).
        let gs = URL(fileURLWithPath: "/Applications/Toolbox.app/Contents/Resources/ghostscript/bin/gs")
        let gsDir = gs.deletingLastPathComponent().path
        let input = URL(fileURLWithPath: "/private/tmp/toolbox-in.pdf")
        let outDir = URL(fileURLWithPath: "/private/tmp", isDirectory: true)

        let profile = SeatbeltProfile.profile(gsPath: gs, readPaths: [input], writePaths: [outDir])

        XCTAssertTrue(profile.contains("(deny default)"), "default-deny is essential to confinement")
        XCTAssertTrue(profile.contains("(import \"system.sb\")"))
        XCTAssertTrue(profile.contains("(import \"bsd.sb\")"))
        XCTAssertTrue(profile.contains("(allow process-exec* (literal \"\(gs.path)\")"))
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertTrue(profile.contains(gsDir), "gs binary directory must be in the read scope")
        XCTAssertTrue(profile.contains("/private/tmp"), "output dir must be in the write scope")
    }

    // MARK: the M1-critical positive test — a REAL sandboxed gs compression

    func testRealSandboxedCompressionProducesSmallerValidPDF() async throws {
        let runner = try GhostscriptRunner()   // bundled gs via Bundle.main
        let input = try Fixtures.imagePDF()
        let outDir = input.deletingLastPathComponent()
        let output = outDir.appendingPathComponent("out-\(UUID().uuidString).pdf")

        let before = TestSupport.fileSize(input)
        XCTAssertGreaterThan(before, 1_000_000, "image fixture should be several MB")

        let result = try await runner.run(
            arguments: ["-sDEVICE=pdfwrite", "-dPDFSETTINGS=/ebook",
                        "-sOutputFile=\(output.path)", input.path],
            readPaths: [input],
            writePaths: [outDir])

        XCTAssertEqual(result.exitCode, 0, "gs failed under sandbox. stderr:\n\(result.stderr)")

        let after = TestSupport.fileSize(output)
        XCTAssertGreaterThan(after, 0, "no output produced")
        XCTAssertLessThan(after, before, "expected real compression: \(before) → \(after) bytes")

        // Valid PDF, page count preserved.
        let inDoc = try XCTUnwrap(PDFDocument(url: input))
        let outDoc = try XCTUnwrap(PDFDocument(url: output), "output is not a valid PDF")
        XCTAssertEqual(outDoc.pageCount, inDoc.pageCount)
        XCTAssertEqual(outDoc.pageCount, 1)
    }

    // MARK: the sandbox actually confines — a write outside the scope is denied

    func testWriteOutsideScopeIsDenied() async throws {
        let runner = try GhostscriptRunner()
        let input = try Fixtures.imagePDF()
        let inDir = input.deletingLastPathComponent()

        // A sibling directory NOT handed to the runner as a write path.
        let forbidden = try Fixtures.uniqueURL("evil.pdf")

        let result = try await runner.run(
            arguments: ["-sDEVICE=pdfwrite", "-dPDFSETTINGS=/ebook",
                        "-sOutputFile=\(forbidden.path)", input.path],
            readPaths: [input],
            writePaths: [inDir])  // only the input's dir is writable, NOT `forbidden`'s dir

        XCTAssertNotEqual(result.exitCode, 0, "gs should be denied writing outside the scope")
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path),
                       "no file should be created outside the write scope")
    }

    // MARK: FIX 3 — a hung gs is terminated at the wall-clock cap and throws a clear error

    func testRunTimesOutAndThrows() async throws {
        // A PostScript program that loops forever — gs spins until the wall-clock cap fires.
        // (Self-checking: an input that errored instantly would *return* a ProcessResult and
        // trip the XCTFail below; only a real hang-then-kill throws `.timedOut`.)
        let ps = try Fixtures.uniqueURL("infinite.ps")
        let dir = ps.deletingLastPathComponent()
        try Data("%!PS-Adobe-3.0\n{ } loop\n".utf8).write(to: ps)
        let output = dir.appendingPathComponent("out.pdf")

        let runner = try GhostscriptRunner(wallClockTimeout: 2)   // bundled gs, tiny cap for the test
        let start = Date()
        do {
            _ = try await runner.run(
                arguments: ["-sDEVICE=pdfwrite", "-sOutputFile=\(output.path)", ps.path],
                readPaths: [ps],
                writePaths: [dir])
            XCTFail("expected a timeout throw for a hanging gs")
        } catch let error as GhostscriptError {
            guard case .timedOut = error else {
                return XCTFail("expected GhostscriptError.timedOut, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 1, "should have waited for the ~2s cap, not failed instantly")
        XCTAssertLessThan(elapsed, 60, "should terminate near the cap, well under the 300s production bound")
    }

    // MARK: S16 — a chatty child's stderr is drained but not retained

    func testDrainTailKeepsOnlyTheTrailingBytes() throws {
        let pipe = Pipe()
        // Under the 64 KB pipe buffer, so the write completes before the drain starts (a larger
        // payload would block the writer here — in production the drain runs concurrently).
        let payload = Data((0..<20_000).map { UInt8($0 % 251) })
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        let tail = GhostscriptRunner.drainTail(pipe.fileHandleForReading, limit: 4096)

        XCTAssertEqual(tail.count, 4096, "output must be capped, not merely read")
        XCTAssertEqual(tail, Data(payload.suffix(4096)), "the kept bytes must be the last ones")
    }

    // MARK: S10 — a child that ignores SIGTERM is escalated to SIGKILL

    /// gs itself dies on SIGTERM (proved by the timeout test above), so the escalation is tested
    /// against a shell that deliberately ignores it — the case the watchdog would otherwise hang
    /// on forever.
    func testTerminateEscalatesToSIGKILL() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do sleep 0.2; done"]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        // Let the trap be installed: signalling before it exists would kill the shell with plain
        // SIGTERM and the test would pass without exercising the escalation at all.
        try await Task.sleep(nanoseconds: 500_000_000)

        let start = Date()
        GhostscriptRunner.terminateEscalating(process, grace: 0.5)

        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(process.isRunning, "a child ignoring SIGTERM must not survive the grace period")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL, "expected SIGKILL, not a plain SIGTERM exit")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "escalation should land just after the grace period")
    }

    // MARK: M1 — cancelling the caller terminates the running gs child

    /// The wall-clock cap is deliberately **generous** here: if the watchdog were what stopped the
    /// run, this test would pass for the wrong reason. The proof that cancellation really killed
    /// gs is the pair of assertions below — `CancellationError` (not `.timedOut`) and a return far
    /// inside the cap. `run` only resumes after `waitUntilExit()` returns, so a prompt return *is*
    /// evidence the child process is gone.
    func testCancellingTheTaskTerminatesGhostscript() async throws {
        let ps = try Fixtures.uniqueURL("infinite-cancel.ps")
        let dir = ps.deletingLastPathComponent()
        try Data("%!PS-Adobe-3.0\n{ } loop\n".utf8).write(to: ps)
        let output = dir.appendingPathComponent("cancelled.pdf")

        let runner = try GhostscriptRunner(wallClockTimeout: 120)
        let start = Date()
        let handle = Task {
            try await runner.run(
                arguments: ["-sDEVICE=pdfwrite", "-sOutputFile=\(output.path)", ps.path],
                readPaths: [ps],
                writePaths: [dir])
        }
        // Let gs actually get going before pulling the plug (launch is well under a second).
        try await Task.sleep(nanoseconds: 1_500_000_000)
        handle.cancel()

        do {
            _ = try await handle.value
            XCTFail("expected the cancelled gs run to throw")
        } catch is CancellationError {
            // expected
        } catch let error as GhostscriptError {
            XCTFail("expected CancellationError, got \(error) — the watchdog, not cancellation, stopped gs")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 30, "cancellation must terminate gs at once, not wait out the 120s cap")
    }
}
