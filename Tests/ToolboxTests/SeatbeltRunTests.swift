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
        // A read path that does NOT share the write path's prefix, so the write-scope
        // assertion below cannot be satisfied by the read line — see T1.
        let input = URL(fileURLWithPath: "/private/var/toolbox-in.pdf")
        let outDir = URL(fileURLWithPath: "/private/tmp", isDirectory: true)

        let profile = SeatbeltProfile.profile(gsPath: gs, readPaths: [input], writePaths: [outDir])

        XCTAssertTrue(profile.contains("(deny default)"), "default-deny is essential to confinement")
        XCTAssertTrue(profile.contains("(import \"system.sb\")"))
        XCTAssertTrue(profile.contains("(import \"bsd.sb\")"))
        XCTAssertTrue(profile.contains("(allow process-exec* (literal \"\(gs.path)\")"))
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertTrue(profile.contains(gsDir), "gs binary directory must be in the read scope")
        // The exact write-scope s-expression: satisfied only by the `file-write*` line, not the
        // read line — deleting the `if !writes.isEmpty { ... }` block in `SeatbeltProfile.profile`
        // now breaks this assertion (T1).
        XCTAssertTrue(profile.contains("(allow file-write* (subpath \"/private/tmp\"))"),
                      "output dir must be in the write scope")
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

    // MARK: the sandbox actually confines — a read outside the scope is denied

    func testReadOutsideScopeIsDenied() async throws {
        let runner = try GhostscriptRunner()
        let input = try Fixtures.imagePDF()
        let outDir = input.deletingLastPathComponent()
        let output = outDir.appendingPathComponent("out-\(UUID().uuidString).pdf")

        let result = try await runner.run(
            arguments: ["-sDEVICE=pdfwrite", "-dPDFSETTINGS=/ebook",
                        "-sOutputFile=\(output.path)", input.path],
            readPaths: [],   // the input's directory is deliberately NOT granted read access
            writePaths: [outDir])

        // Note: gs opens `-sOutputFile=` for writing before it attempts to read the input, so a
        // (possibly empty) file at `output` is not itself evidence one way or the other — the
        // read-scope denial is proven by the non-zero exit alone.
        XCTAssertNotEqual(result.exitCode, 0, "gs should be denied reading outside the scope")
    }

    // Network denial (`(deny network*)`) is NOT proven empirically here. Standard gs/PostScript
    // exposes no operator that opens a socket or fetches a URL, so there is no cheap real gs
    // invocation that would fail differently with vs without that clause — a probe against a
    // different binary (e.g. curl) would really be proving process-exec confinement (already
    // covered: the profile only ever allows-execs `gsPath`), not network denial, and would be
    // faking the claim the review asked not to fake. Left as a string assertion in
    // `testProfileContainsRequiredClauses`; F9's network half remains open pending a cheap real
    // probe (e.g. a build of gs with a network-capable filter, or dropping to a lower-level
    // `sandbox_check`-based check).

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

    // MARK: F4/m5 — page markers are delivered AS THEY ARRIVE, not once after gs has exited

    /// The discriminator against the old behaviour is the tick *count* and *when* the ticks land:
    /// the previous implementation parsed the retained tail after the child exited and called back
    /// exactly once. Here the first two markers are asserted while the writer still holds the pipe
    /// open, so nothing that batches could pass. Also pins the monotonic filter (a repeat and a
    /// regression are dropped) and the bounded line buffer (a huge marker-less line, larger than
    /// the 64 KB pipe buffer, neither breaks the parse nor is retained).
    func testDrainTailReportsPageMarkersAsTheyArrive() throws {
        let pipe = Pipe()
        let lock = NSLock()
        var ticks: [Int] = []
        let firstBatch = expectation(description: "the first two page markers arrive")
        let drained = expectation(description: "the drain reaches EOF")
        DispatchQueue.global().async {
            _ = GhostscriptRunner.drainTail(pipe.fileHandleForReading, limit: 4096) { page in
                lock.lock(); ticks.append(page); let count = ticks.count; lock.unlock()
                if count == 2 { firstBatch.fulfill() }
            }
            drained.fulfill()
        }

        try pipe.fileHandleForWriting.write(
            contentsOf: Data("Processing pages 1 through 3.\nPage 1\nPage 2\n".utf8))
        wait(for: [firstBatch], timeout: 10)
        lock.lock(); let early = ticks; lock.unlock()
        XCTAssertEqual(early, [1, 2], "both markers must arrive while the child still holds the pipe open")

        // A marker-less line far longer than the pipe buffer, then a repeat, a regression and a
        // genuinely newer page.
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 0x78, count: 100_000))
        try pipe.fileHandleForWriting.write(contentsOf: Data("\nPage 2\nPage 1\nPage 3\n".utf8))
        try pipe.fileHandleForWriting.close()
        wait(for: [drained], timeout: 10)

        lock.lock(); let all = ticks; lock.unlock()
        XCTAssertEqual(all, [1, 2, 3], "markers must be reported once each, in increasing order only")
    }

    /// The same, end to end through a real sandboxed gs: a six-page document must report six ticks,
    /// not the single post-exit tick the old parse produced. (Measured: gs's PDF interpreter
    /// line-flushes `Page N` to the pipe as each page is emitted.)
    func testRealGhostscriptReportsEveryPageAsItIsEmitted() async throws {
        let runner = try GhostscriptRunner()   // bundled gs via Bundle.main
        let input = try Fixtures.bornDigitalPDF(pages: 6)
        let outDir = input.deletingLastPathComponent()
        let output = outDir.appendingPathComponent("progress-\(UUID().uuidString).pdf")

        let lock = NSLock()
        var ticks: [Int] = []
        let result = try await runner.run(
            arguments: ["-sDEVICE=pdfwrite", "-dPDFSETTINGS=/ebook",
                        "-sOutputFile=\(output.path)", input.path],
            readPaths: [input],
            writePaths: [outDir],
            onProgress: { page in lock.lock(); ticks.append(page); lock.unlock() })

        XCTAssertEqual(result.exitCode, 0, "gs failed under sandbox. stderr:\n\(result.stderr)")
        lock.lock(); let seen = ticks; lock.unlock()
        XCTAssertGreaterThan(seen.count, 1,
                             "a single tick is the old post-exit parse; streaming reports every page")
        XCTAssertEqual(seen, Array(1...6), "expected one tick per page, in order — got \(seen)")
    }

    // MARK: M1 — a non-UTF-8 byte in gs's diagnostic must not erase the diagnostic

    /// gs echoes the offending token verbatim, so a stray byte in the input lands raw in its own
    /// message (measured: `Error: /undefined in \xff\xfe\xfd` on **stdout**). `String(data:encoding:)`
    /// is failable and would return nil for that, and the old `?? ""` then destroyed the job's
    /// entire failure reason on precisely the untrusted-input path that needs it most.
    func testUndecodableGhostscriptOutputIsRepairedNotDiscarded() async throws {
        let ps = try Fixtures.uniqueURL("undecodable.ps")
        let dir = ps.deletingLastPathComponent()
        var source = Data("%!PS-Adobe-3.0\n/Foo ".utf8)
        source.append(contentsOf: [0xFF, 0xFE, 0xFD])   // never a valid UTF-8 sequence
        source.append(contentsOf: Data(" bar\n".utf8))
        try source.write(to: ps)
        let output = dir.appendingPathComponent("undecodable.pdf")

        let runner = try GhostscriptRunner()
        let result = try await runner.run(
            arguments: ["-sDEVICE=pdfwrite", "-sOutputFile=\(output.path)", ps.path],
            readPaths: [ps],
            writePaths: [dir])

        XCTAssertNotEqual(result.exitCode, 0, "the fixture must make gs fail, or it proves nothing")
        let diagnostic = result.stdout + result.stderr
        XCTAssertTrue(diagnostic.contains("undefined"),
                      "the diagnostic must survive the undecodable bytes, got:\n\(diagnostic)")
        XCTAssertTrue(diagnostic.contains("\u{FFFD}"),
                      "the invalid bytes must be repaired to U+FFFD, not take the message with them")
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
