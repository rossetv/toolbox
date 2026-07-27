// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation

/// A page reduced to one bit per pixel, rows packed MSB-first with **0 = black** — the
/// `DeviceGray` convention, so the bits drop straight into a 1-bit `CGImage`.
struct BilevelBitmap: Equatable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    /// One bit per pixel, MSB first: 1 is white, 0 is black — `/DeviceGray` semantics.
    let bits: [UInt8]

    /// The bitmap as a 1-bit `/DeviceGray` image, ready for CCITT encoding.
    var cgImage: CGImage? {
        guard width > 0, height > 0, bits.count >= bytesPerRow * height else { return nil }
        guard let provider = CGDataProvider(data: Data(bits) as CFData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 1,
                       bitsPerPixel: 1,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// Deciding whether a rendered page is *visually* two-tone, and reducing it to one bit per
/// pixel if it is. This is the front of Rung 2 (spec §5.1): `.scanBilevel` is **content-based**
/// (R2-N5), so an 8-bit greyscale scan that looks black-and-white qualifies and gets binarised —
/// which is what makes CCITT G4 possible on it, and where the large win lives.
///
/// **Binarisation is irreversible in appearance terms, so the gate is deliberately strict and
/// fails closed.** Two independent conditions, both of which a genuine document scan passes
/// comfortably and a photograph does not:
///
/// 1. **Near-greyscale.** Almost no pixel may carry real colour. Luminance alone is not enough:
///    saturated yellow has luminance 226 and would sail through an extremes-only test, so a
///    yellow-on-white page would binarise to a blank sheet.
/// 2. **Two-tone luminance.** Almost every pixel must sit near black or near white; the
///    anti-aliased edges of glyphs are the only material occupants of the middle.
///
/// The page-level gate is applied per page and any failure sends the **whole document** back to
/// Rung 1 — per-page routing inside one document is v1.1 (spec §5.1).
enum BilevelScan {

    /// Fraction of pixels that must be near-black or near-white.
    static let extremeFraction = 0.92
    /// Luminance at or below which a pixel counts as near-black.
    static let darkCeiling = 40
    /// Luminance at or above which a pixel counts as near-white.
    static let lightFloor = 215
    /// Largest channel spread (max − min) a pixel may have and still count as grey. 25, not 40:
    /// inked stamps and pale security patterns live in the 25–40 band (the same band the MRC
    /// classifier's moderate-chroma gate exists for — DECISIONS.md 2026-07-24), and a ceiling of
    /// 40 was blind to them.
    static let chromaCeiling = 25
    /// Fraction of pixels allowed to carry real colour. A stamp, signature or logo occupies well
    /// under 2 % of a page's pixels, so the old 0.02 allowance binarised pages that visibly carry
    /// colour. Measured basis (2026-07-27), at both resolutions the gate runs at — the
    /// classifier's 1500 px sample and the Rung-2 page loop's `bilevelDPI` render (~3508 px for
    /// A4 at 300 DPI): one damaged field document whose inked stamps were flattened reads
    /// 0.011–0.019 at spread > 25 across both; three genuine B/W scan documents (including
    /// noisy/JPEG-cast pages) read ≤ 0.0019 at 1500 px and ≤ 0.0027 at engine resolution — so
    /// 0.005 sits ≥ 1.8× clear of both sides at both resolutions (2.2× on the colour side,
    /// 1.85× on the B/W side at engine resolution). Calibration basis is one
    /// separating document (n=1) plus three B/W documents (n=3) and the synthetic regression
    /// fixture; the residual risk is a B/W corpus outlier declining to Rung 1, which costs
    /// bytes, never quality.
    static let chromaFraction = 0.005

    /// What one pass over a rendered page measures.
    struct PageStatistics: Equatable {
        /// 256-bin luminance histogram over the sampled pixels.
        let histogram: [Int]
        let sampled: Int
        let extremes: Int
        let chromatic: Int

        /// Both gate conditions. See the type comment for why each exists.
        var isNearBilevel: Bool {
            guard sampled > 0 else { return false }
            return Double(extremes) / Double(sampled) > extremeFraction
                && Double(chromatic) / Double(sampled) <= chromaFraction
        }
    }

    /// Measure a rendered RGB page.
    ///
    /// Rows are addressed through `bytesPerRow` and read only across the real `width`. A
    /// `CGImage` row is padded to an alignment boundary and those padding bytes are zero:
    /// walking the buffer flat reads them as pure black, which counts them as "extreme" and
    /// biases the result **towards** declaring a page bilevel — precisely the wrong direction
    /// for a decision that then destroys the page's greys.
    static func analyse(_ image: CGImage) -> PageStatistics? {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let length = CFDataGetLength(data)
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let width = image.width, height = image.height, rowBytes = image.bytesPerRow
        guard bytesPerPixel >= 3, length > 0, width > 0, height > 0,
              rowBytes >= width * bytesPerPixel else { return nil }

        var histogram = [Int](repeating: 0, count: 256)
        var sampled = 0, extremes = 0, chromatic = 0
        for y in 0..<height {
            let rowStart = y * rowBytes
            for x in 0..<width {
                let o = rowStart + x * bytesPerPixel
                guard o + 2 < length else { break }
                let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
                let luminance = (r * 299 + g * 587 + b * 114) / 1000
                histogram[luminance] += 1
                sampled += 1
                if luminance <= darkCeiling || luminance >= lightFloor { extremes += 1 }
                if max(r, max(g, b)) - min(r, min(g, b)) > chromaCeiling { chromatic += 1 }
            }
        }
        return PageStatistics(histogram: histogram, sampled: sampled,
                              extremes: extremes, chromatic: chromatic)
    }

    /// Whether a rendered page is visually near-two-tone (spec R2-N5).
    static func isNearBilevel(_ image: CGImage) -> Bool {
        analyse(image)?.isNearBilevel ?? false
    }

    /// Reduce a rendered RGB page to one bit per pixel, or `nil` if the page **fails the gate** —
    /// the gate and the reduction are one call so no caller can binarise an ungated page.
    static func binarise(_ image: CGImage) -> BilevelBitmap? {
        guard let stats = analyse(image), stats.isNearBilevel,
              let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let length = CFDataGetLength(data)
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let width = image.width, height = image.height, rowBytes = image.bytesPerRow
        // Fail CLOSED on a short buffer rather than open: this is a destructive rebuild (the
        // page is about to be replaced by whatever this produces), so a data provider shorter
        // than the image it claims to back must abort, not silently return a bitmap padded with
        // white for the rows it couldn't read. Hoisted to a single upfront guard rather than a
        // per-row break, which left every unread row as pre-filled white — a wrong answer
        // returned as success. Unreachable with real CoreGraphics buffers.
        guard length >= rowBytes * height else { return nil }
        let threshold = otsuThreshold(stats.histogram)

        let outRow = (width + 7) / 8
        var bits = [UInt8](repeating: 0xFF, count: outRow * height)      // start all-white
        for y in 0..<height {
            let rowStart = y * rowBytes
            let outStart = y * outRow
            for x in 0..<width {
                let o = rowStart + x * bytesPerPixel
                let luminance = (Int(ptr[o]) * 299 + Int(ptr[o + 1]) * 587 + Int(ptr[o + 2]) * 114) / 1000
                if luminance <= threshold {
                    bits[outStart + x / 8] &= ~(UInt8(0x80) >> UInt8(x % 8))   // 0 = black
                }
            }
        }
        return BilevelBitmap(width: width, height: height, bytesPerRow: outRow, bits: bits)
    }

    /// Otsu's method: the threshold maximising between-class variance over the histogram.
    ///
    /// Chosen over a fixed 50 % cut because a scan's paper is rarely white and its ink rarely
    /// black — a fixed threshold turns a slightly-grey background into solid ink (or loses light
    /// text entirely), while Otsu lands in the empty valley the gate has already proved exists.
    ///
    /// On a two-tone page that valley is *wide*, so every threshold across it scores identically
    /// and "first maximum wins" returns a value hard against the ink mode — where a single grain
    /// speck one level lighter than the darkest ink turns white. The **midpoint of the maximal
    /// plateau** is the standard remedy and the reason the plateau is tracked rather than a
    /// single best index.
    static func otsuThreshold(_ histogram: [Int]) -> Int {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 127 }
        var sum = 0.0
        for (value, count) in histogram.enumerated() { sum += Double(value) * Double(count) }

        var sumBackground = 0.0, weightBackground = 0
        var plateauStart = 127, plateauEnd = 127, bestVariance = -1.0
        for t in 0..<256 {
            weightBackground += histogram[t]
            guard weightBackground > 0 else { continue }
            let weightForeground = total - weightBackground
            guard weightForeground > 0 else { break }
            sumBackground += Double(t) * Double(histogram[t])
            let meanBackground = sumBackground / Double(weightBackground)
            let meanForeground = (sum - sumBackground) / Double(weightForeground)
            let delta = meanBackground - meanForeground
            let variance = Double(weightBackground) * Double(weightForeground) * delta * delta
            if variance > bestVariance {
                bestVariance = variance
                plateauStart = t
                plateauEnd = t
            } else if variance == bestVariance {
                plateauEnd = t
            }
        }
        return (plateauStart + plateauEnd) / 2
    }
}
