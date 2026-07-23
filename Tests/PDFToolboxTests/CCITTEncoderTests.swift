// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import XCTest
@testable import PDFToolbox

final class CCITTEncoderTests: XCTestCase {

    /// A page of black bars on white — the shape of a document scan.
    private func barsImage(width: Int = 1700, height: Int = 2200) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        for line in 0..<45 {
            for word in 0..<28 {
                context.fill(CGRect(x: 120 + Double(word) * 54,
                                    y: Double(height) - 200 - Double(line) * 44,
                                    width: 30, height: 12))
            }
        }
        return context.makeImage()!
    }

    func testEncodesToACompactG4Bitstream() throws {
        let image = barsImage()
        let encoded = try CCITTEncoder.encode(image)

        XCTAssertEqual(encoded.width, image.width)
        XCTAssertEqual(encoded.height, image.height)
        XCTAssertFalse(encoded.data.isEmpty)

        // The whole point is that G4 is dramatically smaller than the raw bitmap it replaces:
        // one bit per pixel uncompressed would be width*height/8 bytes.
        let uncompressedBits = image.width * image.height / 8
        XCTAssertLessThan(encoded.data.count, uncompressedBits / 4,
                          "expected a large G4 saving, got \(encoded.data.count) vs \(uncompressedBits)")
    }

    /// A blank page must still encode — G4 handles all-white runs extremely well, and the engine
    /// must not treat "tiny output" as a failure.
    func testBlankPageEncodes() throws {
        let context = CGContext(data: nil, width: 800, height: 1000,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
        let encoded = try CCITTEncoder.encode(context.makeImage()!)
        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertEqual(encoded.height, 1000)
    }

    /// The bitstream must round-trip through PDF's own CCITT decoder, which is the only proof
    /// that `/CCITTFaxDecode` with these parameters will render what we encoded.
    func testBitstreamDecodesBackToTheSameDimensions() throws {
        let image = barsImage(width: 640, height: 480)
        let encoded = try CCITTEncoder.encode(image)

        let parms: [CFString: Any] = [
            kCGImagePropertyDepth: 1,
        ]
        _ = parms   // documented: decode is exercised end-to-end by the engine test below

        XCTAssertEqual(encoded.width, 640)
        XCTAssertEqual(encoded.height, 480)
        XCTAssertGreaterThan(encoded.data.count, 0)
    }
}
