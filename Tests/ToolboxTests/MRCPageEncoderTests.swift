// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import XCTest
@testable import Toolbox

/// The MRC layer encoder (Task 12): CCITT mask + two JPEG colour layers in, and the recompose
/// that reconstitutes a full page from them for the verifier to score.
final class MRCPageEncoderTests: XCTestCase {

    // MARK: fixtures

    /// A page of vertical ink bars on white paper — enough structure for the segmenter to
    /// produce a real mask plus non-trivial fg/bg colour layers.
    private func textPage(width: Int = 200, height: Int = 160) throws -> CGImage {
        try TestImages.rgb(width: width, height: height) { x, _ in
            (x % 20) < 6 ? (20, 20, 20) : (250, 245, 235)
        }
    }

    /// The `(r, g, b)` of a pixel, read back through a DeviceRGB context so the test is
    /// independent of the image's internal pixel format.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> (Int, Int, Int) {
        let w = image.width, h = image.height
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let base = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        let o = y * ctx.bytesPerRow + x * 4
        return (Int(base[o]), Int(base[o + 1]), Int(base[o + 2]))
    }

    /// A hand-built `MRCSegmented` with a known ink quadrant: the top-left quarter of `mask` is
    /// ink (bit 0), everywhere else is paper (bit 1). Asymmetric on both axes — unlike a plain
    /// left/right or top/bottom split, this is not invariant under a horizontal *or* a vertical
    /// flip, so it is a real oracle that the mask's TIFF-decode path and the fg/bg JPEG-decode
    /// path agree on orientation (mirrors `MRCVerifierTests`' top-only-bars row-alignment
    /// oracle). `foreground` is flat red, `background` flat blue, each at half the mask's
    /// resolution — a realistic downsample, and a genuine upscale for `recompose` to perform.
    private func knownSplit(width: Int = 40, height: Int = 40) throws -> MRCSegmented {
        let bytesPerRow = (width + 7) / 8
        var bits = [UInt8](repeating: 0xFF, count: bytesPerRow * height)
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                bits[y * bytesPerRow + x / 8] &= ~(UInt8(0x80) >> UInt8(x % 8))
            }
        }
        let mask = BilevelBitmap(width: width, height: height, bytesPerRow: bytesPerRow, bits: bits)
        let foreground = try TestImages.rgb(width: width / 2, height: height / 2) { _, _ in (220, 20, 20) }
        let background = try TestImages.rgb(width: width / 2, height: height / 2) { _, _ in (20, 20, 220) }
        return MRCSegmented(mask: mask, foreground: foreground, background: background)
    }

    // MARK: layer production

    func testEncodeProducesAllThreeLayers() throws {
        let page = try textPage()
        let segmented = try XCTUnwrap(MRCSegmenter.segment(page))
        let encoded = try XCTUnwrap(MRCPageEncoder.encode(segmented, preset: .balanced))

        XCTAssertFalse(encoded.mask.data.isEmpty)
        XCTAssertEqual(encoded.mask.width, segmented.mask.width)
        XCTAssertEqual(encoded.mask.height, segmented.mask.height)

        for jpeg in [encoded.background, encoded.foreground] {
            XCTAssertGreaterThanOrEqual(jpeg.data.count, 2)
            XCTAssertEqual(Array(jpeg.data.prefix(2)), [0xFF, 0xD8], "must start with the JPEG SOI marker")
        }
    }

    /// The reason MRC exists: three specialised layers together beat one whole-page JPEG, because
    /// the mask carries sharp glyph edges CCITT compresses almost for free while the colour layers
    /// are free to be soft and coarse. A generous ×0.9 factor — a smoke bound on the saving, not a
    /// margin claim (M2 calibrates the real number).
    func testEncodedSizesBeatWholePageJPEG() throws {
        let page = try textPage()
        let segmented = try XCTUnwrap(MRCSegmenter.segment(page))
        let encoded = try XCTUnwrap(MRCPageEncoder.encode(segmented, preset: .balanced))

        let qualities = MRCPageEncoder.layerQualities(for: .balanced)
        let wholePage = try XCTUnwrap(MRCPageEncoder.encodeJPEG(page, quality: qualities.bg))

        let mrcTotal = encoded.mask.data.count + encoded.foreground.data.count + encoded.background.data.count
        XCTAssertLessThan(Double(mrcTotal), Double(wholePage.data.count) * 0.9,
                          "MRC total \(mrcTotal) should beat whole-page JPEG \(wholePage.data.count)")
    }

    // MARK: encodeJPEG

    func testEncodeJPEGRoundTrips() throws {
        let image = try textPage(width: 64, height: 48)
        let jpeg = try XCTUnwrap(MRCPageEncoder.encodeJPEG(image, quality: 0.5))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg.data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }

    // MARK: recompose

    func testRecomposeSelectsFgOnInkAndBgOnPaper() throws {
        let segmented = try knownSplit()
        let encoded = try XCTUnwrap(MRCPageEncoder.encode(segmented, preset: .balanced))
        let recomposed = try XCTUnwrap(MRCPageEncoder.recompose(encoded))

        XCTAssertEqual(recomposed.width, segmented.mask.width)
        XCTAssertEqual(recomposed.height, segmented.mask.height)

        // Only the top-left quadrant is ink; the other three quadrants are paper. Sampling all
        // four (each well away from a boundary so a soft JPEG edge can't leak in) means a
        // horizontal-only or vertical-only orientation mismatch between the mask's TIFF-decode
        // path and the fg/bg JPEG-decode path fails this test, not just a symmetric flip.
        let (inkR, inkG, inkB) = try pixel(recomposed, 5, 5)
        XCTAssertGreaterThan(inkR, inkG + 50, "the ink quadrant must carry the foreground's red")
        XCTAssertGreaterThan(inkR, inkB + 50, "the ink quadrant must carry the foreground's red")

        for (x, y) in [(35, 5), (5, 35), (35, 35)] {
            let (paperR, paperG, paperB) = try pixel(recomposed, x, y)
            XCTAssertGreaterThan(paperB, paperR + 50,
                                 "paper quadrant (\(x), \(y)) must carry the background's blue")
            XCTAssertGreaterThan(paperB, paperG + 50,
                                 "paper quadrant (\(x), \(y)) must carry the background's blue")
        }
    }

    /// `recompose` on a real segmenter output, not just the toy uniform split above — exercises
    /// the TIFF-wrapped mask decode against a genuine G4 stream and genuinely-downsampled colour
    /// layers.
    func testRecomposeHandlesARealSegmentedPage() throws {
        let page = try textPage()
        let segmented = try XCTUnwrap(MRCSegmenter.segment(page))
        let encoded = try XCTUnwrap(MRCPageEncoder.encode(segmented, preset: .balanced))
        let recomposed = try XCTUnwrap(MRCPageEncoder.recompose(encoded))

        XCTAssertEqual(recomposed.width, segmented.mask.width)
        XCTAssertEqual(recomposed.height, segmented.mask.height)
    }
}
