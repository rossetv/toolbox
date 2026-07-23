// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import PDFKit
import XCTest
@testable import Toolbox

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
        let encoded = try XCTUnwrap(CCITTEncoder.encode(image))

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
        let encoded = try XCTUnwrap(CCITTEncoder.encode(context.makeImage()!))
        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertEqual(encoded.height, 1000)
    }

    /// The bitstream must round-trip through PDF's own CCITT decoder — the only real proof that
    /// `/CCITTFaxDecode` with these parameters renders what was encoded. Composes the strip into
    /// a genuine one-page PDF (sized 1:1 in points to the image's pixel dimensions), renders that
    /// page back at the same pixel size, and compares the result pixel-for-pixel against the
    /// source used to encode it — a wrong `/K`, `/Columns`/`/Rows`, or `/BlackIs1` would show up
    /// here as gross misalignment or a global inversion, not as a few soft edges.
    func testBitstreamDecodesBackToTheSourcePixels() throws {
        let image = barsImage(width: 640, height: 480)
        let encoded = try XCTUnwrap(CCITTEncoder.encode(image))

        let data = try BilevelPDFComposer.compose(pages: [
            .init(image: encoded, size: CGSize(width: image.width, height: image.height)),
        ])
        let document = try XCTUnwrap(PDFDocument(data: data), "composed bytes must open as a PDF")
        let page = try XCTUnwrap(document.page(at: 0))
        let decoded = try PDFService().render(page, maxDimension: CGFloat(image.width))

        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)

        guard let sourceData = image.dataProvider?.data, let sourcePtr = CFDataGetBytePtr(sourceData),
              let decodedData = decoded.dataProvider?.data, let decodedPtr = CFDataGetBytePtr(decodedData)
        else {
            return XCTFail("could not access source/decoded pixel buffers")
        }
        let sourceRowBytes = image.bytesPerRow
        let sourceBPP = max(1, image.bitsPerPixel / 8)
        let decodedRowBytes = decoded.bytesPerRow
        let decodedBPP = max(1, decoded.bitsPerPixel / 8)

        var matches = 0, total = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let sourceDark = Int(sourcePtr[y * sourceRowBytes + x * sourceBPP]) < 128
                let decodedDark = Int(decodedPtr[y * decodedRowBytes + x * decodedBPP]) < 128
                if sourceDark == decodedDark { matches += 1 }
                total += 1
            }
        }
        let matchFraction = Double(matches) / Double(total)
        XCTAssertGreaterThan(matchFraction, 0.95,
                             "decoded page must match the source pixel-for-pixel "
                             + "(matched \(matchFraction * 100)%)")
    }

    // MARK: - TIFF strip parser hardening (`CCITTEncoder.strip(fromTIFF:)`)
    //
    // ImageIO's own output never exercises these guards (a single modest strip, every time), so
    // only a hand-crafted TIFF can prove they fire.

    /// Regression: a multi-strip TIFF must be rejected outright, not silently concatenated into
    /// one bitstream that would decode as garbage past the first strip's boundary.
    func testMultiStripTIFFIsRejectedNotConcatenated() {
        let strip1: [UInt8] = [0xAA, 0xBB, 0xCC]
        let strip2: [UInt8] = [0xDD, 0xEE]

        func entries(offsets: [Int]) -> [TIFFBuilder.Entry] {
            [.init(tag: 262, type: 3, count: 1, value: [0, 0]),                                // photometric
             .init(tag: 273, type: 4, count: 2, value: TIFFBuilder.longValues(offsets)),        // StripOffsets
             .init(tag: 279, type: 4, count: 2,                                                 // StripByteCounts
                  value: TIFFBuilder.longValues([strip1.count, strip2.count]))]
        }
        // First pass with placeholder offsets, purely to learn where `trailingData` will land —
        // the layout size depends only on the entries' byte lengths, not their values.
        let (_, trailingOffset) = TIFFBuilder.build(entries: entries(offsets: [0, 0]), trailingData: Data())
        let realOffsets = [trailingOffset, trailingOffset + strip1.count]
        let (tiff, _) = TIFFBuilder.build(entries: entries(offsets: realOffsets),
                                          trailingData: Data(strip1 + strip2))

        XCTAssertNil(CCITTEncoder.strip(fromTIFF: tiff),
                    "a multi-strip TIFF must be rejected, not concatenated into an undecodable bitstream")
    }

    /// Regression: a declared value count wildly out of proportion to the buffer must be
    /// rejected by a bounds check, never iterated — an unbounded `count` (up to `UInt32.max`)
    /// would otherwise turn the parser into a multi-million-iteration loop over a TIFF a few
    /// dozen bytes long.
    func testAbsurdDeclaredCountIsRejectedInstantlyNotIterated() {
        let entries: [TIFFBuilder.Entry] = [
            .init(tag: 273, type: 4, count: 20_000_000, value: TIFFBuilder.longValues([0])),
        ]
        let (tiff, _) = TIFFBuilder.build(entries: entries, trailingData: Data())

        let start = Date()
        let strip = CCITTEncoder.strip(fromTIFF: tiff)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(strip)
        XCTAssertLessThan(elapsed, 2.0,
                          "an absurd declared count must be rejected by bounds-checking against "
                          + "the buffer size, not iterated (took \(elapsed)s)")
    }
}

/// Minimal hand-built little-endian TIFF (single IFD), for feeding deliberately malformed input
/// directly to `CCITTEncoder.strip(fromTIFF:)` — real ImageIO output never varies enough to
/// exercise these paths.
private enum TIFFBuilder {
    struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        let value: [UInt8]
    }

    /// Builds `header + IFD + out-of-line entry values + trailingData`, returning the bytes and
    /// the absolute offset at which `trailingData` begins (so callers can compute offsets INTO
    /// it — e.g. strip locations — before it exists, in a first pass with placeholder values).
    static func build(entries: [Entry], trailingData: Data) -> (data: Data, trailingOffset: Int) {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }

        let ifdOffset = 8
        var overflowOffset = ifdOffset + 2 + entries.count * 12 + 4
        var ifdBody: [UInt8] = u16(entries.count)
        var overflow: [UInt8] = []
        for entry in entries {
            ifdBody += u16(entry.tag) + u16(entry.type) + u32(entry.count)
            if entry.value.count <= 4 {
                ifdBody += entry.value + [UInt8](repeating: 0, count: 4 - entry.value.count)
            } else {
                ifdBody += u32(overflowOffset)
                overflow += entry.value
                overflowOffset += entry.value.count
            }
        }
        ifdBody += u32(0)   // no next IFD

        var bytes: [UInt8] = [0x49, 0x49] + u16(42) + u32(ifdOffset)
        bytes += ifdBody
        bytes += overflow
        let trailingOffset = bytes.count
        bytes += Array(trailingData)
        return (Data(bytes), trailingOffset)
    }

    /// TIFF LONG (type 4) values, 4 bytes each, little-endian.
    static func longValues(_ values: [Int]) -> [UInt8] {
        values.flatMap { v in
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
    }
}
