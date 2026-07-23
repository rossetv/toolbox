// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
@testable import PDFToolbox

final class FileNamingTests: XCTestCase {

    private func uniqueDir() throws -> URL {
        try Fixtures.uniqueURL("placeholder").deletingLastPathComponent()
    }

    func testBasicSuffixAlongsideInput() throws {
        let dir = try uniqueDir()
        let input = dir.appendingPathComponent("report.pdf")
        let output = FileNaming.output(for: input, suffix: "compressed", folder: nil)
        XCTAssertEqual(output.lastPathComponent, "report-compressed.pdf")
        XCTAssertEqual(output.deletingLastPathComponent().path, dir.path)
    }

    func testCollisionAppendsCounter() throws {
        let dir = try uniqueDir()
        let input = dir.appendingPathComponent("report.pdf")
        // First output already exists on disk.
        try Data("x".utf8).write(to: dir.appendingPathComponent("report-compressed.pdf"))
        let output = FileNaming.output(for: input, suffix: "compressed", folder: nil)
        XCTAssertEqual(output.lastPathComponent, "report-compressed-1.pdf")
    }

    func testFolderOverride() throws {
        let inputDir = try uniqueDir()
        let outDir = try uniqueDir()
        let input = inputDir.appendingPathComponent("scan.pdf")
        let output = FileNaming.output(for: input, suffix: "ocr", folder: outDir)
        XCTAssertEqual(output.lastPathComponent, "scan-ocr.pdf")
        XCTAssertEqual(output.deletingLastPathComponent().path, outDir.path)
    }

    /// Regression: two inputs with the SAME basename from DIFFERENT folders, both directed at the
    /// same output folder, must get distinct output names even though neither exists on disk yet.
    /// A purely on-disk check returns the same name for both (TOCTOU race under concurrency); the
    /// reserving set makes the up-front allocation collision-free.
    func testBatchReservationAvoidsSameBasenameCollision() throws {
        let folderA = try uniqueDir()
        let folderB = try uniqueDir()
        let outDir = try uniqueDir()
        let inputA = folderA.appendingPathComponent("image.pdf")
        let inputB = folderB.appendingPathComponent("image.pdf")   // same basename, different folder

        var reserved = Set<String>()
        let outA = FileNaming.output(for: inputA, suffix: "compressed", folder: outDir, reserving: &reserved)
        let outB = FileNaming.output(for: inputB, suffix: "compressed", folder: outDir, reserving: &reserved)

        XCTAssertNotEqual(outA, outB, "same-basename batch inputs must get distinct outputs")
        XCTAssertEqual(outA.lastPathComponent, "image-compressed.pdf")
        XCTAssertEqual(outB.lastPathComponent, "image-compressed-1.pdf")
    }

    /// MAJOR 1 regression: APFS is case-insensitive by default, so `Report.pdf` and `report.pdf`
    /// resolve to the SAME file on disk even though they're different basenames. A byte-exact
    /// `Set<URL>` reservation would let both "reserve" distinct candidates that later collide at
    /// `moveItem`; the reservation must be keyed case- (and normalisation-) insensitively.
    func testBatchReservationIsCaseInsensitive() throws {
        let folderA = try uniqueDir()
        let folderB = try uniqueDir()
        let outDir = try uniqueDir()
        let inputA = folderA.appendingPathComponent("Report.pdf")
        let inputB = folderB.appendingPathComponent("report.pdf")   // same name, different case

        var reserved = Set<String>()
        let outA = FileNaming.output(for: inputA, suffix: "compressed", folder: outDir, reserving: &reserved)
        let outB = FileNaming.output(for: inputB, suffix: "compressed", folder: outDir, reserving: &reserved)

        XCTAssertNotEqual(outA.path.lowercased(), outB.path.lowercased(),
                           "case-differing batch inputs must not resolve to the same on-disk path")
        XCTAssertEqual(outA.lastPathComponent, "Report-compressed.pdf")
        XCTAssertEqual(outB.lastPathComponent, "report-compressed-1.pdf")
    }

    /// MINOR 5 regression: macOS filenames are capped at 255 UTF-8 bytes. An untruncated ~300-char
    /// basename would exit the dedupe loop only to fail `moveItem` with `ENAMETOOLONG` every time.
    func testLongBasenameIsTruncatedToFitFilesystemLimit() throws {
        let dir = try uniqueDir()
        let longName = String(repeating: "a", count: 300)
        let input = dir.appendingPathComponent("\(longName).pdf")

        let output = FileNaming.output(for: input, suffix: "compressed", folder: nil)

        XCTAssertLessThanOrEqual(output.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(output.lastPathComponent.hasSuffix("-compressed.pdf"),
                      "suffix and extension must survive truncation")
    }

    /// Same limit, but with multi-byte (3-bytes-per-character) CJK text: truncation must land on a
    /// whole character boundary, never split a scalar mid-way through.
    func testLongCJKBasenameIsTruncatedWithoutSplittingCharacters() throws {
        let dir = try uniqueDir()
        let longName = String(repeating: "字", count: 120)   // ~360 UTF-8 bytes
        let input = dir.appendingPathComponent("\(longName).pdf")

        let output = FileNaming.output(for: input, suffix: "compressed", folder: nil)

        XCTAssertLessThanOrEqual(output.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(output.lastPathComponent.hasSuffix("-compressed.pdf"))
        XCTAssertFalse(output.lastPathComponent.contains("\u{FFFD}"),
                        "truncation must not split a multi-byte character")
    }
}
