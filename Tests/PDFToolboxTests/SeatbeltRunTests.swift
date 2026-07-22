// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import PDFKit
import XCTest
@testable import PDFToolbox

final class SeatbeltRunTests: XCTestCase {

    // MARK: profile string shape

    func testProfileContainsRequiredClauses() {
        // Any gs URL works for string-shape assertions (no launch).
        let gs = URL(fileURLWithPath: "/Applications/PDFToolbox.app/Contents/Resources/ghostscript/bin/gs")
        let gsDir = gs.deletingLastPathComponent().path
        let input = URL(fileURLWithPath: "/private/tmp/pdftoolbox-in.pdf")
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

    func testRealSandboxedCompressionProducesSmallerValidPDF() throws {
        let runner = try GhostscriptRunner()   // bundled gs via Bundle.main
        let input = try Fixtures.imagePDF()
        let outDir = input.deletingLastPathComponent()
        let output = outDir.appendingPathComponent("out-\(UUID().uuidString).pdf")

        let before = TestSupport.fileSize(input)
        XCTAssertGreaterThan(before, 1_000_000, "image fixture should be several MB")

        let result = try runner.run(
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

    func testWriteOutsideScopeIsDenied() throws {
        let runner = try GhostscriptRunner()
        let input = try Fixtures.imagePDF()
        let inDir = input.deletingLastPathComponent()

        // A sibling directory NOT handed to the runner as a write path.
        let forbidden = try Fixtures.uniqueURL("evil.pdf")

        let result = try runner.run(
            arguments: ["-sDEVICE=pdfwrite", "-dPDFSETTINGS=/ebook",
                        "-sOutputFile=\(forbidden.path)", input.path],
            readPaths: [input],
            writePaths: [inDir])  // only the input's dir is writable, NOT `forbidden`'s dir

        XCTAssertNotEqual(result.exitCode, 0, "gs should be denied writing outside the scope")
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path),
                       "no file should be created outside the write scope")
    }
}
