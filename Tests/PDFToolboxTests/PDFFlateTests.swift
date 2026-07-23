// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Foundation
import XCTest
@testable import PDFToolbox

final class PDFFlateTests: XCTestCase {

    func testRoundTripsARealZlibStream() throws {
        let original = Data(String(repeating: "1 0 << /Type /Catalog >> ", count: 200).utf8)
        let compressed = try Fixtures.zlibCompress(original)
        XCTAssertLessThan(compressed.count, original.count, "precondition: it really compressed")
        XCTAssertEqual([UInt8](compressed.prefix(2)), [0x78, 0x9C], "a genuine zlib header")

        let inflated = try XCTUnwrap(PDFFlate.inflate([UInt8](compressed), limit: 1 << 20))
        XCTAssertEqual(Data(inflated), original)
    }

    /// A stream's compressed size says nothing about its expanded size, and the body is
    /// untrusted: a few kilobytes of deflate expands to gigabytes of zeroes.
    func testDecompressionBombIsRefusedAtTheLimit() throws {
        let bomb = try Fixtures.zlibCompress(Data(repeating: 0, count: 8 << 20))
        XCTAssertLessThan(bomb.count, 64 << 10, "precondition: a small stream, a huge expansion")

        XCTAssertNil(PDFFlate.inflate([UInt8](bomb), limit: 1 << 20),
                     "expanding past the limit must fail, not allocate")
        XCTAssertNotNil(PDFFlate.inflate([UInt8](bomb), limit: 16 << 20),
                        "the same stream decodes when the budget allows it")
    }

    func testGarbageAndTruncatedInputAreRefused() throws {
        XCTAssertNil(PDFFlate.inflate([UInt8]("not compressed at all".utf8), limit: 1 << 20))
        XCTAssertNil(PDFFlate.inflate([], limit: 1 << 20))

        let compressed = try Fixtures.zlibCompress(Data(String(repeating: "x", count: 4096).utf8))
        XCTAssertNil(PDFFlate.inflate([UInt8](compressed.prefix(compressed.count / 2)), limit: 1 << 20),
                     "a truncated body must not yield a partial result presented as complete")
    }
}
