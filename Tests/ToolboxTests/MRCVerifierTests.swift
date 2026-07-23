// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import XCTest
@testable import Toolbox

/// Ink-weighted visual verification (spec R4, C3). The three contracts here encode the whole
/// reason the component exists: blank paper must not dominate the measurement, and the error must
/// be relative to the input page's own contrast so faint and bold pages calibrate the same.
final class MRCVerifierTests: XCTestCase {

    // MARK: fixtures

    // Bars live in the TOP rows only; the bottom is left blank. The asymmetry is deliberate: it
    // is the test's only oracle that the mask (built by `binarise`, top-down) and the verifier's
    // grey buffers (drawn into a context, then read back) are row-aligned — a vertical flip in
    // either path would move the ink region off the bars and the background test below would
    // wrongly pass.
    private let width = 64, height = 48
    private let inkRows = 28
    private let barWidth = 3, barGap = 5

    /// A vertical-bar text pattern: `inkLuma` bars on white paper, bars confined to the top
    /// `inkRows` rows. `r = g = b = luma`, so the grey render round-trips the value.
    private func bars(inkLuma: Int) -> [[Int]] {
        var grid = [[Int]](repeating: [Int](repeating: 255, count: width), count: height)
        for y in 0..<inkRows {
            for x in 0..<width where x % (barWidth + barGap) < barWidth {
                grid[y][x] = inkLuma
            }
        }
        return grid
    }

    /// A box blur of `grid`, replacing only the pixels `include(x, y)` accepts with the mean of
    /// their `(2r+1)²` window; every other pixel keeps its original value. Blur is linear, which
    /// is what makes the relative-scoring invariance in `testRelativeScoringIsContrastIndependent`
    /// exact rather than approximate.
    private func boxBlur(_ grid: [[Int]], radius: Int, include: (Int, Int) -> Bool) -> [[Int]] {
        var out = grid
        for y in 0..<height {
            for x in 0..<width where include(x, y) {
                var sum = 0, count = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let ny = y + dy, nx = x + dx
                        guard ny >= 0, ny < height, nx >= 0, nx < width else { continue }
                        sum += grid[ny][nx]; count += 1
                    }
                }
                out[y][x] = sum / count
            }
        }
        return out
    }

    private func image(_ grid: [[Int]]) throws -> CGImage {
        try TestImages.rgb(width: width, height: height) { x, y in
            (grid[y][x], grid[y][x], grid[y][x])
        }
    }

    private func inInkRows(_ x: Int, _ y: Int) -> Bool { y < inkRows }

    // MARK: tests

    /// The candidate being the input itself scores exactly zero and passes.
    func testIdentityScoresZero() throws {
        let input = try image(bars(inkLuma: 0))
        let mask = try XCTUnwrap(BilevelScan.binarise(input))
        let score = try XCTUnwrap(MRCVerifier.score(candidate: input, input: input, mask: mask))
        XCTAssertEqual(score.normalisedError, 0, accuracy: 1e-9)
        XCTAssertTrue(score.pass)
    }

    /// Over-compression that smears glyph edges (a blur over the ink rows) fails; the *same*
    /// severity of corruption applied only to blank background — a large near-black block well
    /// below the ink — passes, because the measurement is confined to the dilated ink region and
    /// blank paper is excluded. This is the metric trap the component exists to avoid.
    func testInkRegionCorruptionFailsButBackgroundCorruptionPasses() throws {
        let clean = bars(inkLuma: 0)
        let input = try image(clean)
        let mask = try XCTUnwrap(BilevelScan.binarise(input))

        // Ink smeared: blur the ink rows heavily.
        let inkCorrupted = try image(boxBlur(clean, radius: 3, include: inInkRows))
        let inkScore = try XCTUnwrap(MRCVerifier.score(candidate: inkCorrupted, input: input, mask: mask))
        XCTAssertFalse(inkScore.pass, "smeared glyphs must fail, got \(inkScore.normalisedError)")
        XCTAssertGreaterThan(inkScore.normalisedError, MRCVerifier.maxNormalisedError)

        // Background wrecked far from the ink: a naive whole-page metric would scream, yet the
        // ink region is untouched, so the page must pass. The block starts well below the 2 px
        // dilation of the ink at row \(inkRows - 1).
        var wrecked = clean
        for y in (inkRows + 6)..<height { for x in 0..<width { wrecked[y][x] = 10 } }
        let bgCorrupted = try image(wrecked)
        let bgScore = try XCTUnwrap(MRCVerifier.score(candidate: bgCorrupted, input: input, mask: mask))
        XCTAssertTrue(bgScore.pass, "background-only damage must pass, got \(bgScore.normalisedError)")
        XCTAssertEqual(bgScore.normalisedError, 0, accuracy: 1e-9)
    }

    /// A faint page and a bold page suffering the *same relative* degradation score the same
    /// (C3 self-calibration). The mask is shared from the high-contrast twin: the faint page's own
    /// render would not clear `binarise`'s near-bilevel gate, and identical geometry is exactly
    /// what the invariance requires — same region, same pixel set, same n.
    func testRelativeScoringIsContrastIndependent() throws {
        // Precondition: the DeviceRGB→DeviceGray render must be linear on the grey axis, or the
        // affine relationship the invariance rests on breaks nonlinearly. Confirm r=g=b=v ≈ v.
        XCTAssertEqual(try midGreyRoundTrip(), 128, accuracy: 3,
                       "grey render is gamma-shifted; the invariance below no longer holds exactly")

        let boldGrid = bars(inkLuma: 0)      // paper 255, ink 0
        let faintGrid = bars(inkLuma: 160)   // paper 255, ink 160 — same geometry, less contrast
        let bold = try image(boldGrid)
        let faint = try image(faintGrid)
        let mask = try XCTUnwrap(BilevelScan.binarise(bold))

        let boldCandidate = try image(boxBlur(boldGrid, radius: 2, include: inInkRows))
        let faintCandidate = try image(boxBlur(faintGrid, radius: 2, include: inInkRows))

        let boldScore = try XCTUnwrap(MRCVerifier.score(candidate: boldCandidate, input: bold, mask: mask))
        let faintScore = try XCTUnwrap(MRCVerifier.score(candidate: faintCandidate, input: faint, mask: mask))

        XCTAssertEqual(faintScore.normalisedError, boldScore.normalisedError, accuracy: 0.02,
                       "equal relative degradation must score the same regardless of contrast")
        // Both must FAIL — the point of the test. Without C3 normalisation the faint page's small
        // absolute diff would slip under an absolute threshold and wrongly pass; contrast-relative
        // scoring makes it fail exactly as the bold page does.
        XCTAssertFalse(boldScore.pass, "bold page must fail, got \(boldScore.normalisedError)")
        XCTAssertFalse(faintScore.pass, "faint page must fail the same way, got \(faintScore.normalisedError)")
    }

    /// A candidate whose size differs from the input fails closed rather than resampling.
    func testDimensionMismatchFailsClosed() throws {
        let input = try image(bars(inkLuma: 0))
        let mask = try XCTUnwrap(BilevelScan.binarise(input))
        let smaller = try TestImages.rgb(width: width - 1, height: height) { _, _ in (0, 0, 0) }
        XCTAssertNil(MRCVerifier.score(candidate: smaller, input: input, mask: mask))
    }

    // MARK: helpers

    /// Draw a solid mid-grey (r=g=b=128) into an 8-bit `DeviceGray` context and read it back — the
    /// verifier's own render path. Returns the recovered luminance.
    private func midGreyRoundTrip() throws -> Int {
        let source = try TestImages.rgb(width: 4, height: 4) { _, _ in (128, 128, 128) }
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.interpolationQuality = .none
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        let base = try XCTUnwrap(ctx.data?.assumingMemoryBound(to: UInt8.self))
        return Int(base[0])
    }
}
