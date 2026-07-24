// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation

/// Visual verification of an MRC-compressed page against its input (spec R4, C3).
///
/// Whole-page similarity is worthless here: a document page is mostly blank paper, so a
/// candidate whose glyphs have dissolved into mush still scores as near-identical because the
/// paper — which dominates the pixel count — is untouched. That is the metric trap the earlier
/// spike fell into. The fix is two-fold and both halves are load-bearing:
///
///  1. **Measure only over the ink region** — the mask's black pixels dilated by 2 px, so glyph
///     bodies *and* the halo where ringing and smearing land are weighted, and blank paper is
///     excluded entirely.
///  2. **Normalise by the input page's own contrast in that region** (C3), not an absolute floor.
///     A faint scan and a bold one that suffer the *same relative* degradation then score the
///     same — the page self-calibrates against how much contrast it actually had to lose.
enum MRCVerifier {

    struct Score: Equatable {
        let normalisedError: Double
        let pass: Bool
    }

    /// The largest normalised error a page may carry and still pass. M2-calibrated later; this is
    /// a deliberately conservative start. Because the error is relative to the input page's own
    /// contrast (C3), the same constant serves sparse, faint and bold pages alike.
    // M2-calibrated 2026-07-24: measured good MRC pages (text-class corpus, calibrated
    // layer factors) span 0.21-0.30; genuine encode corruption scores well above. NOTE
    // (recorded limitation): image-dominant harm lives OFF the ink mask, so this metric
    // does not separate it - the classifier envelope is the exclusion mechanism for that
    // class (measured: it excluded every harmful corpus page); this gate catches encode
    // corruption within the masked text region.
    static let maxNormalisedError = 0.33

    /// Contrast below which the ink region is treated as near-uniform — nothing MRC could have
    /// destroyed — and the page passes trivially. Truly blank pages are already screened by the
    /// classifier's `minInkCoverage`; this guards the arithmetic against dividing by a
    /// near-zero standard deviation.
    static let minInkContrast = 4.0

    /// Score `candidate` against `input` over the dilated `mask` ink region.
    ///
    /// Returns `nil` — fail closed — when the candidate's dimensions differ from the input's, or
    /// the mask's from either: the three buffers are indexed together, so a mismatch has no
    /// meaningful answer and resampling would fabricate one.
    static func score(candidate: CGImage, input: CGImage, mask: BilevelBitmap) -> Score? {
        let width = input.width, height = input.height
        guard width > 0, height > 0,
              candidate.width == width, candidate.height == height,
              mask.width == width, mask.height == height else { return nil }

        guard let inputGrey = MRCSegmenter.greyBuffer(of: input, width: width, height: height,
                                                       interpolation: .none),
              let candidateGrey = MRCSegmenter.greyBuffer(of: candidate, width: width, height: height,
                                                           interpolation: .none)
        else { return nil }

        let region = dilatedInkRegion(mask, width: width, height: height)

        var n = 0
        var sumDiff = 0.0, sumInput = 0.0, sumInputSq = 0.0
        for i in 0..<(width * height) where region[i] {
            n += 1
            let c = Double(candidateGrey[i]), v = Double(inputGrey[i])
            sumDiff += abs(c - v)
            sumInput += v
            sumInputSq += v * v
        }
        // No ink to verify: same disposition as a near-uniform region.
        guard n > 0 else { return Score(normalisedError: 0, pass: true) }

        let meanAbsDiff = sumDiff / Double(n)
        let meanInput = sumInput / Double(n)
        let variance = max(0, sumInputSq / Double(n) - meanInput * meanInput)
        let inputContrast = variance.squareRoot()
        guard inputContrast >= minInkContrast else { return Score(normalisedError: 0, pass: true) }

        let normalisedError = meanAbsDiff / inputContrast
        return Score(normalisedError: normalisedError, pass: normalisedError <= maxNormalisedError)
    }

    /// The mask's ink (bit == 0) dilated by 2 px — two passes of an 8-neighbour maximum. The mask
    /// is read bit-addressed (byte `y·bytesPerRow + x/8`, bit `7 − x%8`, C1); only the real
    /// `width` is walked, never a row's padding bits.
    private static func dilatedInkRegion(_ mask: BilevelBitmap, width: Int, height: Int) -> [Bool] {
        var region = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let rowByte = y * mask.bytesPerRow
            for x in 0..<width {
                let bit = (mask.bits[rowByte + x / 8] >> UInt8(7 - x % 8)) & 1
                if bit == 0 { region[y * width + x] = true }   // 0 = black = ink
            }
        }
        region = dilateOnce(region, width: width, height: height)
        region = dilateOnce(region, width: width, height: height)
        return region
    }

    /// One 8-neighbour dilation pass: a pixel joins the region if it, or any of its eight
    /// neighbours, was already in it.
    private static func dilateOnce(_ src: [Bool], width: Int, height: Int) -> [Bool] {
        var dst = src
        for y in 0..<height {
            for x in 0..<width where !src[y * width + x] {
                var hit = false
                var dy = -1
                while dy <= 1 && !hit {
                    var dx = -1
                    while dx <= 1 {
                        let ny = y + dy, nx = x + dx
                        if ny >= 0, ny < height, nx >= 0, nx < width, src[ny * width + nx] {
                            hit = true
                            break
                        }
                        dx += 1
                    }
                    dy += 1
                }
                if hit { dst[y * width + x] = true }
            }
        }
        return dst
    }
}
