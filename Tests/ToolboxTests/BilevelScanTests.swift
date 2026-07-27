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

/// The Rung-2 gate and binarisation step. Binarisation is irreversible in appearance terms, so
/// most of these tests are about what must **not** be binarised.
final class BilevelScanTests: XCTestCase {

    // MARK: helpers

    /// A flat RGB image of one colour — the simplest input with row padding to get wrong.
    private func solid(_ red: Int, _ green: Int, _ blue: Int,
                       width: Int = 61, height: Int = 37) throws -> CGImage {
        try TestImages.rgb(width: width, height: height) { _, _ in (red, green, blue) }
    }

    private func renderFirstPage(_ url: URL, maxDimension: CGFloat = 1200) throws -> CGImage {
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(doc.page(at: 0))
        return try PDFService().render(page, maxDimension: maxDimension)
    }

    /// Fraction of bits that are 0 (black) in a packed bitmap, ignoring the row's padding bits.
    private func blackFraction(_ bitmap: BilevelBitmap) -> Double {
        var black = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where
                bitmap.bits[y * bitmap.bytesPerRow + x / 8] & (UInt8(0x80) >> UInt8(x % 8)) == 0 {
                black += 1
            }
        }
        return Double(black) / Double(bitmap.width * bitmap.height)
    }

    // MARK: the gate

    /// A `CGImage` row is padded to an alignment boundary and the padding bytes are zero. Read
    /// flat they look like pure black pixels, which inflates the "extreme" count and biases the
    /// gate towards binarising pages it must not touch. Sampling exactly `width × height` pixels
    /// is the discriminating check: a flat walk over the buffer samples more than that.
    func testRowPaddingIsNotSampled() throws {
        let width = 61, height = 37                       // 61×4 = 244 B/row, padded by CoreGraphics
        let image = try solid(255, 255, 255, width: width, height: height)
        XCTAssertGreaterThan(image.bytesPerRow, width * 4, "the fixture must actually be padded")

        let stats = try XCTUnwrap(BilevelScan.analyse(image))
        XCTAssertEqual(stats.sampled, width * height, "padding bytes must not be sampled as pixels")
        XCTAssertEqual(stats.extremes, width * height)
        XCTAssertEqual(stats.chromatic, 0)
        XCTAssertEqual(stats.histogram[255], width * height, "a white page is all-white")
    }

    /// Saturated yellow has luminance 226 — "near-white" to a luminance-only test — so a
    /// yellow-on-white page would pass an extremes-only gate and binarise to a blank sheet.
    /// The chroma condition is what stops it.
    func testSaturatedColourPageIsNotBilevel() throws {
        let image = try TestImages.rgb(width: 200, height: 200) { x, _ in
            x < 120 ? (255, 255, 0) : (255, 255, 255)     // yellow block on white
        }
        let stats = try XCTUnwrap(BilevelScan.analyse(image))
        XCTAssertGreaterThan(Double(stats.extremes) / Double(stats.sampled), BilevelScan.extremeFraction,
                             "the fixture must be luminance-extreme, or this test proves nothing")
        XCTAssertFalse(stats.isNearBilevel, "a saturated two-tone page must not be called bilevel")
        XCTAssertNil(BilevelScan.binarise(image))
    }

    /// A mostly-B/W scan carrying a small colour element — an inked stamp, a signature, a logo —
    /// must NOT binarise: the element occupies ~1 % of the page, which the pre-2026-07-27 gate
    /// (spread > 40, allowance 2 %) waved through, flattening a real document's inked stamps to
    /// black and white in the field. Two element chromas are exercised: a strong one (spread 45, over even
    /// the old ceiling but under the old 2 % allowance) and a moderate one (spread 30 — the
    /// 25–40 band the old ceiling was entirely blind to). Both fixtures are luminance-extreme,
    /// so the chroma condition is the only thing standing between them and binarisation.
    func testSmallColourStampIsNotBinarised() throws {
        for (name, stamp) in [("strong", (255, 210, 210)), ("moderate", (255, 225, 225))] {
            let image = try TestImages.rgb(width: 200, height: 200) { x, y in
                // 20×20 stamp block = 1 % of pixels; the rest a plain black-on-white page.
                if x < 20 && y < 20 { return stamp }
                return y % 10 == 0 ? (0, 0, 0) : (255, 255, 255)
            }
            let stats = try XCTUnwrap(BilevelScan.analyse(image))
            XCTAssertGreaterThan(Double(stats.extremes) / Double(stats.sampled),
                                 BilevelScan.extremeFraction,
                                 "\(name): fixture must be luminance-extreme, or this proves nothing")
            XCTAssertFalse(stats.isNearBilevel,
                           "\(name): a page with a ~1 % colour stamp must not be called bilevel")
            XCTAssertNil(BilevelScan.binarise(image), "\(name): stamp colour must survive")
        }
    }

    /// The other side of the tightened gate: legitimate B/W scans with sub-threshold chroma —
    /// JPEG colour cast (spread below the 25 ceiling) or a trace colour element under the 0.005
    /// allowance — must STILL binarise, or the tightening trades a colour-destruction bug for a
    /// silent loss of the CCITT win the rung exists for.
    func testSubThresholdChromaStillBinarises() throws {
        // "cast": every non-ink pixel tinted (255,240,235) — spread 20, page-wide, the real
        // shape of a JPEG colour cast. "trace": a 12×12 element at spread 30, 0.36 % coverage —
        // over the ceiling but under the allowance.
        for (name, makePixel) in [
            ("cast", { (x: Int, y: Int) -> (Int, Int, Int) in
                y % 10 == 0 ? (0, 0, 0) : (255, 240, 235)
            }),
            ("trace", { (x: Int, y: Int) -> (Int, Int, Int) in
                if x < 12 && y < 12 { return (255, 225, 225) }
                return y % 10 == 0 ? (0, 0, 0) : (255, 255, 255)
            }),
        ] {
            let image = try TestImages.rgb(width: 200, height: 200, pixel: makePixel)
            let stats = try XCTUnwrap(BilevelScan.analyse(image))
            XCTAssertTrue(stats.isNearBilevel,
                          "\(name): sub-threshold chroma must not cost the page its CCITT rebuild")
            XCTAssertNotNil(BilevelScan.binarise(image), "\(name): page must still binarise")
        }
    }

    /// A continuous-tone greyscale page (no colour to fail the chroma test) must still be
    /// rejected: its luminances fill the middle of the range.
    func testGreyGradientPageIsNotBilevel() throws {
        let image = try TestImages.rgb(width: 256, height: 64) { x, _ in (x, x, x) }
        let stats = try XCTUnwrap(BilevelScan.analyse(image))
        XCTAssertEqual(stats.chromatic, 0, "a grey ramp carries no colour")
        XCTAssertFalse(stats.isNearBilevel, "a full luminance ramp is not two-tone")
        XCTAssertNil(BilevelScan.binarise(image))
    }

    func testPhotoPageIsNotBinarised() throws {
        let image = try renderFirstPage(Fixtures.imagePDF())
        XCTAssertFalse(BilevelScan.isNearBilevel(image))
        XCTAssertNil(BilevelScan.binarise(image), "a photo must never be binarised")
    }

    /// The router's own classification must still agree after the gate was tightened.
    func testGreyscaleScanClassifiesAsBilevelAndPhotoDoesNot() throws {
        let service = PDFService()
        XCTAssertEqual(try service.classify(Fixtures.greyscaleScanPDF()), .scanBilevel)
        XCTAssertEqual(try service.classify(Fixtures.imagePDF()), .scanColour)
    }

    // MARK: binarisation

    func testBinarisesGreyscaleScanPreservingInk() throws {
        let image = try renderFirstPage(Fixtures.greyscaleScanPDF(), maxDimension: 2200)
        let source = try XCTUnwrap(BilevelScan.analyse(image))
        let bitmap = try XCTUnwrap(BilevelScan.binarise(image), "a greyscale scan must binarise")

        XCTAssertEqual(bitmap.width, image.width)
        XCTAssertEqual(bitmap.height, image.height)
        XCTAssertEqual(bitmap.bytesPerRow, (image.width + 7) / 8)
        XCTAssertEqual(bitmap.bits.count, bitmap.bytesPerRow * bitmap.height)

        // The ink survives: the fraction of black pixels tracks the source page's dark pixels.
        let sourceDark = Double(source.histogram[0...BilevelScan.darkCeiling].reduce(0, +))
            / Double(source.sampled)
        let black = blackFraction(bitmap)
        XCTAssertGreaterThan(black, 0.01, "the page has visible ink; binarising must keep it")
        XCTAssertEqual(black, sourceDark, accuracy: 0.03,
                       "binarised ink should track the source's dark pixels, got \(black) vs \(sourceDark)")
    }

    /// A page whose ink sits on light-grey paper: a fixed 50 % cut would keep the paper white
    /// only by luck, so the threshold must land between the two modes, not at a constant.
    func testOtsuThresholdLandsBetweenTheModes() {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[20] = 1000                              // ink
        histogram[235] = 9000                             // paper
        let threshold = BilevelScan.otsuThreshold(histogram)
        XCTAssertGreaterThan(threshold, 20)
        XCTAssertLessThan(threshold, 235)
    }

    func testOtsuOnAnEmptyHistogramIsSafe() {
        XCTAssertEqual(BilevelScan.otsuThreshold([Int](repeating: 0, count: 256)), 127)
    }

    func testAnalyseRejectsAnImageWithTooFewChannels() throws {
        // 1-bit grey: no per-channel bytes to read, so there is nothing to measure.
        let bits = [UInt8](repeating: 0xFF, count: 8 * 8)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bits) as CFData))
        let mono = try XCTUnwrap(CGImage(width: 8, height: 8, bitsPerComponent: 1, bitsPerPixel: 1,
                                         bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                         decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        XCTAssertNil(BilevelScan.analyse(mono))
        XCTAssertNil(BilevelScan.binarise(mono))
    }
}

/// Small synthetic `CGImage`s built pixel by pixel — the inputs the PDF fixtures cannot express
/// (an exact colour, an exact ramp, a chosen size that forces row padding).
enum TestImages {
    enum ImageError: Error { case contextCreation, render }

    /// An RGB image whose pixels come from `pixel(x, y) -> (r, g, b)`.
    static func rgb(width: Int, height: Int,
                    pixel: (Int, Int) -> (Int, Int, Int)) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let base = ctx.data else { throw ImageError.contextCreation }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let o = y * ctx.bytesPerRow + x * 4
                ptr[o] = UInt8(clamping: r); ptr[o + 1] = UInt8(clamping: g)
                ptr[o + 2] = UInt8(clamping: b); ptr[o + 3] = 0xFF
            }
        }
        guard let image = ctx.makeImage() else { throw ImageError.render }
        return image
    }
}
