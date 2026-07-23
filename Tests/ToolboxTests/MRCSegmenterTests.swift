// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation
import XCTest
@testable import Toolbox

/// The Sauvola text-mask binarisation (Task 10). These prove the mask covers ink and spares
/// paper, that the local threshold survives thin strokes and background gradients a global
/// threshold would flood, and — the C1 invariant — that only the compact grey buffer is read
/// so row padding never leaks into the mask.
final class MRCSegmenterTests: XCTestCase {

    // MARK: helpers

    /// A grey-on-white `CGImage` from a per-pixel luminance function. Channels are set equal
    /// (R=G=B) so `greyBuffer`'s DeviceGray conversion yields the exact value back.
    private func grey(width: Int, height: Int,
                      _ luminance: (Int, Int) -> Int) throws -> CGImage {
        try TestImages.rgb(width: width, height: height) { x, y in
            let v = luminance(x, y)
            return (v, v, v)
        }
    }

    /// Whether the mask marks (x, y) as ink (bit 0 = black, MSB-first).
    private func isInk(_ bitmap: BilevelBitmap, _ x: Int, _ y: Int) -> Bool {
        bitmap.bits[y * bitmap.bytesPerRow + x / 8] & (UInt8(0x80) >> UInt8(x % 8)) == 0
    }

    /// The (r, g, b) of a colour-layer pixel, read back through a DeviceRGB context so the test is
    /// independent of the layer's internal pixel format.
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

    // MARK: the mask

    /// Black bars on white paper: the mask must cover almost all bar pixels and almost no
    /// paper. Bars are 6 px wide — narrower than the 31 px window, so every bar pixel's
    /// neighbourhood still contains paper and Sauvola detects it (a bar wider than the window
    /// would have an all-black centre neighbourhood the local threshold cannot see).
    func testMaskCoversGlyphsNotPaper() throws {
        let width = 200, height = 120, barWidth = 6, period = 20
        let image = try grey(width: width, height: height) { x, _ in
            (x % period) < barWidth ? 0 : 255
        }
        let mask = try XCTUnwrap(MRCSegmenter.binarise(image))

        var barPixels = 0, barInk = 0, paperPixels = 0, paperInk = 0
        for y in 0..<height {
            for x in 0..<width {
                if (x % period) < barWidth {
                    barPixels += 1
                    if isInk(mask, x, y) { barInk += 1 }
                } else {
                    paperPixels += 1
                    if isInk(mask, x, y) { paperInk += 1 }
                }
            }
        }
        XCTAssertGreaterThan(Double(barInk) / Double(barPixels), 0.90,
                             "the mask must cover the bars")
        XCTAssertLessThan(Double(paperInk) / Double(paperPixels), 0.02,
                          "the mask must spare the paper")
    }

    /// Thin 1-px strokes survive binarisation (spec §9: no dropped thin strokes). Strokes are
    /// axis-aligned and long, so under 4-connected speck removal they form one component well
    /// above the minimum area — a 1-px *diagonal* would not be 4-connected (see report).
    func testThinStrokesSurvive() throws {
        let width = 160, height = 160
        // A 1-px horizontal rule and a 1-px vertical rule crossing on white paper.
        let hy = 80, vx = 80
        let image = try grey(width: width, height: height) { x, y in
            (y == hy || x == vx) ? 0 : 255
        }
        let mask = try XCTUnwrap(MRCSegmenter.binarise(image))

        var strokePixels = 0, strokeInk = 0
        for y in 0..<height {
            for x in 0..<width where (y == hy || x == vx) {
                strokePixels += 1
                if isInk(mask, x, y) { strokeInk += 1 }
            }
        }
        XCTAssertGreaterThan(Double(strokeInk) / Double(strokePixels), 0.90,
                             "1-px strokes must not be dropped")
    }

    /// Sauvola is local: dark text on a mild luminance gradient binarises cleanly. The gradient
    /// spans 150…230 across the width — gentle enough to be near-uniform inside any 31-px
    /// window — where a single global Otsu threshold would flood the dark half of the page.
    func testGradientBackgroundDoesNotFlood() throws {
        let width = 240, height = 120
        let glyph: (Int, Int) -> Bool = { x, y in
            x >= 40 && x < 46 && y >= 40 && y < 80        // one 6×40 dark bar
        }
        let image = try grey(width: width, height: height) { x, y in
            glyph(x, y) ? 20 : 150 + (80 * x) / width     // dark bar over a 150…230 ramp
        }
        let mask = try XCTUnwrap(MRCSegmenter.binarise(image))

        var glyphPixels = 0, glyphInk = 0, bgPixels = 0, bgInk = 0
        for y in 0..<height {
            for x in 0..<width {
                if glyph(x, y) {
                    glyphPixels += 1
                    if isInk(mask, x, y) { glyphInk += 1 }
                } else {
                    bgPixels += 1
                    if isInk(mask, x, y) { bgInk += 1 }
                }
            }
        }
        XCTAssertGreaterThan(Double(glyphInk) / Double(glyphPixels), 0.90,
                             "the text must be covered even over a gradient")
        XCTAssertLessThan(Double(bgInk) / Double(bgPixels), 0.02,
                          "the gradient background must not flood into ink")
    }

    /// C1 regression: an odd width forces `CGContext` to pad each row. Reading that padding
    /// (zero bytes = black under DeviceGray) with the padded stride mistaken for the compact
    /// width smears each row diagonally, inking paper columns and clearing bar columns. The test
    /// is *structural*, not aggregate: a whole-page ink-fraction comparison survives such a
    /// smear (a vertical-bar pattern's per-row ink count is invariant to a horizontal shift), so
    /// it must assert per-column that bars stay inked and paper stays clean on the odd-width mask.
    func testOddWidthPaddingRegression() throws {
        // Certify the odd width genuinely pads a DeviceGray 8bpc row (mirrors BilevelScan's
        // padding regression): without padding this test would guard nothing.
        let oddWidth = 61, height = 80, barWidth = 6, period = 20
        let probe = try XCTUnwrap(CGContext(data: nil, width: oddWidth, height: height,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceGray(),
                                            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        XCTAssertGreaterThan(probe.bytesPerRow, oddWidth, "the fixture width must force row padding")

        let image = try grey(width: oddWidth, height: height) { x, _ in
            (x % period) < barWidth ? 0 : 255
        }
        let mask = try XCTUnwrap(MRCSegmenter.binarise(image))

        var barPixels = 0, barInk = 0, paperPixels = 0, paperInk = 0
        for y in 0..<height {
            for x in 0..<oddWidth {
                if (x % period) < barWidth {
                    barPixels += 1
                    if isInk(mask, x, y) { barInk += 1 }
                } else {
                    paperPixels += 1
                    if isInk(mask, x, y) { paperInk += 1 }
                }
            }
        }
        XCTAssertGreaterThan(Double(barInk) / Double(barPixels), 0.90,
                             "bars stay covered at an odd width")
        XCTAssertLessThan(Double(paperInk) / Double(paperPixels), 0.02,
                          "a stride-vs-width mix-up would smear ink into the paper columns (C1)")
    }

    // MARK: speck removal

    /// A component below the minimum area is a scanner speck and is cleared; one at the exact
    /// limit (area 3) survives — pinning the `< minComponentArea` boundary against an off-by-one
    /// that a 2-vs-4 test alone would pass under. A 2×2 block (area 4) survives too.
    func testRemoveSpecksDropsSpecksKeepsBlocks() {
        let w = 10, h = 10
        var ink = [Bool](repeating: false, count: w * h)
        // A 1-px isolated speck (area 1) and a 2-px pair (area 2) — both below the limit.
        ink[1 * w + 1] = true
        ink[3 * w + 3] = true; ink[3 * w + 4] = true
        // A 3-px component (area 3, exactly the limit) — "smaller than 3" is cleared, so it stays.
        ink[5 * w + 0] = true; ink[5 * w + 1] = true; ink[5 * w + 2] = true
        // A 2×2 block (area 4) — above the limit, must survive.
        ink[7 * w + 6] = true; ink[7 * w + 7] = true
        ink[8 * w + 6] = true; ink[8 * w + 7] = true

        MRCSegmenter.removeSpecks(&ink, width: w, height: h)

        XCTAssertFalse(ink[1 * w + 1], "an area-1 speck must be cleared")
        XCTAssertFalse(ink[3 * w + 3], "an area-2 component must be cleared")
        XCTAssertFalse(ink[3 * w + 4])
        XCTAssertTrue(ink[5 * w + 0], "an area-3 component (the exact limit) must survive")
        XCTAssertTrue(ink[5 * w + 1])
        XCTAssertTrue(ink[5 * w + 2])
        XCTAssertTrue(ink[7 * w + 6], "a 2×2 block must survive")
        XCTAssertTrue(ink[7 * w + 7])
        XCTAssertTrue(ink[8 * w + 6])
        XCTAssertTrue(ink[8 * w + 7])
    }

    // MARK: bit packing

    /// `packBits` produces BilevelBitmap's convention: MSB-first, 0 = black at ink positions,
    /// rows padded to whole bytes. Read the bits straight back (the `cgImage` accessor wraps the
    /// same buffer, so a non-nil image certifies the dimensions and stride are self-consistent).
    func testPackBitsMatchesBilevelConvention() {
        let w = 10, h = 3                                  // 10 px → 2 bytes/row (6 padding bits)
        var ink = [Bool](repeating: false, count: w * h)
        ink[0 * w + 0] = true                             // top-left ink → MSB of byte 0 clear
        ink[0 * w + 9] = true                             // x=9 → bit 1 of byte 1 (0x40) clear
        ink[2 * w + 5] = true                             // last row, mid byte 0

        let bitmap = MRCSegmenter.packBits(ink, width: w, height: h)

        XCTAssertEqual(bitmap.width, w)
        XCTAssertEqual(bitmap.height, h)
        XCTAssertEqual(bitmap.bytesPerRow, 2)
        XCTAssertEqual(bitmap.bits.count, 2 * h)
        XCTAssertTrue(isInk(bitmap, 0, 0))
        XCTAssertTrue(isInk(bitmap, 9, 0))
        XCTAssertTrue(isInk(bitmap, 5, 2))
        XCTAssertFalse(isInk(bitmap, 1, 0), "a non-ink pixel stays white")
        XCTAssertFalse(isInk(bitmap, 5, 1))
        XCTAssertNotNil(bitmap.cgImage, "the packed bitmap must form a valid 1-bit image")
    }

    // MARK: colour layers

    /// A uniform ink colour drawn as vertical bars must survive into the foreground layer. The fg
    /// block averages *only* the ink-masked pixels, so any block over a bar carries the drawn ink
    /// colour to within Δ24/channel — and blocks with no ink at all inherit ink from their known
    /// neighbours by spreading, so the fg layer never encodes paper where a glyph was cut out.
    func testForegroundCarriesInkColour() throws {
        let width = 120, height = 60, barWidth = 6, period = 12
        let ink = (r: 30, g: 40, b: 110)
        let image = try TestImages.rgb(width: width, height: height) { x, _ in
            (x % period) < barWidth ? ink : (255, 255, 255)
        }
        let seg = try XCTUnwrap(MRCSegmenter.segment(image))
        let fg = seg.foreground
        let f = MRCSegmenter.fgDownsample

        // Every fg block whose whole footprint lies inside a bar must read back as the ink colour.
        var checked = 0
        for by in 0..<fg.height {
            for bx in 0..<fg.width {
                let x0 = bx * f, x1 = min(width, x0 + f)
                guard x1 > x0, (x0..<x1).allSatisfy({ ($0 % period) < barWidth }) else { continue }
                let (r, g, b) = try pixel(fg, bx, by)
                XCTAssertLessThanOrEqual(abs(r - ink.r), 24, "fg red off at block \(bx),\(by)")
                XCTAssertLessThanOrEqual(abs(g - ink.g), 24, "fg green off at block \(bx),\(by)")
                XCTAssertLessThanOrEqual(abs(b - ink.b), 24, "fg blue off at block \(bx),\(by)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "the fixture must contain fg blocks fully inside a bar")
    }

    /// The background layer at glyph positions must carry the *local* paper through, filled by
    /// neighbour spreading — not ink, and not the page-wide mean. Built directly on a synthetic
    /// mask so the test controls exactly which pixels are ink (no dependence on Sauvola coverage):
    /// a horizontal paper gradient (red falls 250→131 across the width) with two full-height ink
    /// bars. A bg block sitting entirely on a bar has no paper pixel, so it is filled by spreading
    /// from its paper neighbours — and must take the paper colour *local to that bar*. The global
    /// mean (red ≈ 190) would fail both bounds, so passing this test requires real spreading.
    func testBackgroundCarriesPaperThroughGlyphs() throws {
        let width = 120, height = 40
        let ink = (30, 40, 110)
        let inBar: (Int) -> Bool = { x in (x >= 20 && x < 26) || (x >= 94 && x < 100) }
        let paperRed: (Int) -> Int = { x in 250 - x }        // 250 (left) … 131 (right)
        let image = try TestImages.rgb(width: width, height: height) { x, _ in
            inBar(x) ? ink : (paperRed(x), paperRed(x), 255)
        }
        var inkArray = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where inBar(x) { inkArray[y * width + x] = true }
        }
        let mask = MRCSegmenter.packBits(inkArray, width: width, height: height)
        let bg = try XCTUnwrap(MRCSegmenter.colourLayer(of: image, mask: mask,
                                                        factor: MRCSegmenter.bgDownsample,
                                                        wantInk: false))

        // Interior blocks of each bar (bx = input-x / 2): the left bar's centre and the right bar's.
        let (lr, lg, lb) = try pixel(bg, 22 / MRCSegmenter.bgDownsample, 0)
        let (rr, _, rb) = try pixel(bg, 96 / MRCSegmenter.bgDownsample, 0)
        XCTAssertGreaterThan(lb, 200, "the left glyph block must be paper, not ink")
        XCTAssertGreaterThan(rb, 200, "the right glyph block must be paper, not ink")
        XCTAssertGreaterThan(lr, 210, "the left glyph block must carry local (bright) paper, not the page mean")
        XCTAssertLessThan(rr, 175, "the right glyph block must carry local (dark) paper, not the page mean")
        _ = (lg)   // green tracks red on this fixture; red already discriminates local vs global.
    }

    /// Layer dimensions are `ceil(mask / factor)` on each side. An asymmetric page (91 × 100) also
    /// pins that width and height are not transposed: fg (÷3) → 31 × 34, bg (÷2) → 46 × 50.
    func testLayerDimensions() throws {
        let width = 91, height = 100
        let image = try grey(width: width, height: height) { x, _ in (x % 20) < 6 ? 0 : 255 }
        let seg = try XCTUnwrap(MRCSegmenter.segment(image))

        XCTAssertEqual(seg.foreground.width, 31, "fg width = ceil(91/3)")
        XCTAssertEqual(seg.foreground.height, 34, "fg height = ceil(100/3)")
        XCTAssertEqual(seg.background.width, 46, "bg width = ceil(91/2)")
        XCTAssertEqual(seg.background.height, 50, "bg height = ceil(100/2)")
    }

    /// `segment` fails closed. Its only nil path is `binarise` → `greyBuffer` failing to build a
    /// same-size DeviceGray context, which happens only for a zero-dimension image — and
    /// CoreGraphics refuses to construct such an image at all, so no constructible CGImage can
    /// reach the guard. This asserts that platform reality (as BilevelPDFComposer's refusal test
    /// does) instead of leaving it a comment, and confirms the smallest valid page segments
    /// without crashing rather than tripping an off-by-one in the ceil/spreading edge.
    func testSegmentDeclinesOnUnbinarisablePage() throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 0, count: 16) as CFData))
        let degenerate = CGImage(width: 0, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false,
                                 intent: .defaultIntent)
        XCTAssertNil(degenerate,
                     "CoreGraphics must refuse a zero-width image — segment's nil guard is defensive")

        let tiny = try grey(width: 1, height: 1) { _, _ in 128 }
        XCTAssertNotNil(MRCSegmenter.segment(tiny), "a 1×1 page must segment without crashing")
    }
}
