// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
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

        var reserved = Set<URL>()
        let outA = FileNaming.output(for: inputA, suffix: "compressed", folder: outDir, reserving: &reserved)
        let outB = FileNaming.output(for: inputB, suffix: "compressed", folder: outDir, reserving: &reserved)

        XCTAssertNotEqual(outA, outB, "same-basename batch inputs must get distinct outputs")
        XCTAssertEqual(outA.lastPathComponent, "image-compressed.pdf")
        XCTAssertEqual(outB.lastPathComponent, "image-compressed-1.pdf")
    }
}
