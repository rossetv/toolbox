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
}
