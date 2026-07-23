// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation

/// The result of an MRC split: the 1-bit text mask plus the two colour layers it separates the
/// page into. The foreground carries ink colour at `fgDownsample`× scale, the background carries
/// paper/illustration at `bgDownsample`× scale; JPEG compresses both cheaply because each has had
/// the other class's hard edges spread away.
struct MRCSegmented {
    let mask: BilevelBitmap
    let foreground: CGImage
    let background: CGImage
}

/// The MRC split: Sauvola-class local-threshold text mask (this file), plus fg/bg colour
/// layers (Task 11). A port of the reference pipeline's approach, calibrated against the
/// reference tool's outputs at the M2 gate — the spike proved the approach, not this port.
enum MRCSegmenter {

    /// The background layer is downsampled 2× and the foreground 3×: paper detail matters more
    /// than ink detail (ink is carried sharply by the 1-bit mask), so the fg can be coarser.
    static let bgDownsample = 2
    static let fgDownsample = 3

    static let sauvolaWindow = 31
    static let sauvolaK = 0.3
    /// Sauvola's dynamic-range normaliser (half the 8-bit range, the standard choice).
    static let sauvolaR = 128.0
    /// Components smaller than this (px) are scanner specks, removed from the mask.
    static let minComponentArea = 3

    static func binarise(_ image: CGImage) -> BilevelBitmap? {
        guard let grey = greyBuffer(of: image) else { return nil }
        let w = grey.width, h = grey.height
        // Integral images of luminance and luminance² → O(1) local mean/stddev per pixel.
        // (w+1)×(h+1), row 0 / column 0 zero.
        var sum = [Double](repeating: 0, count: (w + 1) * (h + 1))
        var sumSq = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0.0, rowSumSq = 0.0
            for x in 0..<w {
                let v = Double(grey.pixels[y * w + x])
                rowSum += v; rowSumSq += v * v
                sum[(y + 1) * (w + 1) + (x + 1)] = sum[y * (w + 1) + (x + 1)] + rowSum
                sumSq[(y + 1) * (w + 1) + (x + 1)] = sumSq[y * (w + 1) + (x + 1)] + rowSumSq
            }
        }
        let half = sauvolaWindow / 2
        var ink = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - half), y1 = min(h - 1, y + half)
            for x in 0..<w {
                let x0 = max(0, x - half), x1 = min(w - 1, x + half)
                let n = Double((x1 - x0 + 1) * (y1 - y0 + 1))
                let s = sum[(y1 + 1) * (w + 1) + (x1 + 1)] - sum[y0 * (w + 1) + (x1 + 1)]
                      - sum[(y1 + 1) * (w + 1) + x0] + sum[y0 * (w + 1) + x0]
                let sq = sumSq[(y1 + 1) * (w + 1) + (x1 + 1)] - sumSq[y0 * (w + 1) + (x1 + 1)]
                       - sumSq[(y1 + 1) * (w + 1) + x0] + sumSq[y0 * (w + 1) + x0]
                let mean = s / n
                let variance = max(0, sq / n - mean * mean)
                let threshold = mean * (1 + sauvolaK * (variance.squareRoot() / sauvolaR - 1))
                ink[y * w + x] = Double(grey.pixels[y * w + x]) < threshold
            }
        }
        removeSpecks(&ink, width: w, height: h)
        return packBits(ink, width: w, height: h)
    }

    /// The full MRC split of a page: the text mask plus a foreground (ink) and background (paper)
    /// colour layer. Fails closed — any stage returning nil declines the whole page, so a caller
    /// never sees a partial segmentation.
    static func segment(_ image: CGImage) -> MRCSegmented? {
        guard let mask = binarise(image),
              let fg = colourLayer(of: image, mask: mask, factor: fgDownsample, wantInk: true),
              let bg = colourLayer(of: image, mask: mask, factor: bgDownsample, wantInk: false)
        else { return nil }
        return MRCSegmented(mask: mask, foreground: fg, background: bg)
    }

    /// Build one colour layer at 1/factor scale. Each output block averages the input pixels of the
    /// wanted class (ink for fg, paper for bg) inside its factor×factor footprint; blocks containing
    /// none are filled by iterative neighbour spreading, so JPEG never encodes a hard edge where the
    /// other class was cut out (the reference pipeline's fg/bg-spreading idea, block-granular).
    static func colourLayer(of image: CGImage, mask: BilevelBitmap,
                            factor: Int, wantInk: Bool) -> CGImage? {
        // 1. Compact RGB buffer of `image`, row-addressed like greyBuffer (real width only, C1).
        guard let rgb = rgbBuffer(of: image) else { return nil }
        let w = rgb.width, h = rgb.height
        let blocksWide = (w + factor - 1) / factor      // ceil(w / factor)
        let blocksHigh = (h + factor - 1) / factor
        let count = blocksWide * blocksHigh
        var colour = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: count)
        var known = [Bool](repeating: false, count: count)

        // 2. Block means over the wanted class (mask bit == wantInk; ink = bit 0).
        for by in 0..<blocksHigh {
            let y0 = by * factor, y1 = min(h, y0 + factor)
            for bx in 0..<blocksWide {
                let x0 = bx * factor, x1 = min(w, x0 + factor)
                var sr = 0.0, sg = 0.0, sb = 0.0, n = 0
                for y in y0..<y1 {
                    for x in x0..<x1 where maskIsInk(mask, x, y) == wantInk {
                        let o = (y * w + x) * 4
                        sr += Double(rgb.pixels[o]); sg += Double(rgb.pixels[o + 1])
                        sb += Double(rgb.pixels[o + 2]); n += 1
                    }
                }
                if n > 0 {
                    colour[by * blocksWide + bx] = (sr / Double(n), sg / Double(n), sb / Double(n))
                    known[by * blocksWide + bx] = true
                }
            }
        }

        // 3. Spreading: each pass reads only the previous pass's knowledge (double-buffered), so an
        //    unknown block takes the mean of its known 8-neighbours and turns known. Bounded by
        //    (blocksWide + blocksHigh) passes — the longest a fill can have to travel.
        for _ in 0..<(blocksWide + blocksHigh) where !known.allSatisfy({ $0 }) {
            var nextColour = colour, nextKnown = known, changed = false
            for by in 0..<blocksHigh {
                for bx in 0..<blocksWide where !known[by * blocksWide + bx] {
                    var sr = 0.0, sg = 0.0, sb = 0.0, n = 0
                    for dy in -1...1 {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            let nx = bx + dx, ny = by + dy
                            guard nx >= 0, nx < blocksWide, ny >= 0, ny < blocksHigh else { continue }
                            let ni = ny * blocksWide + nx
                            if known[ni] {
                                sr += colour[ni].r; sg += colour[ni].g; sb += colour[ni].b; n += 1
                            }
                        }
                    }
                    if n > 0 {
                        nextColour[by * blocksWide + bx] = (sr / Double(n), sg / Double(n), sb / Double(n))
                        nextKnown[by * blocksWide + bx] = true
                        changed = true
                    }
                }
            }
            colour = nextColour; known = nextKnown
            if !changed { break }                       // an isolated island: nothing left to reach it
        }

        // Any block still unknown after the cap → global mean of the known blocks, else mid-grey.
        if !known.allSatisfy({ $0 }) {
            var sr = 0.0, sg = 0.0, sb = 0.0, n = 0
            for i in 0..<count where known[i] { sr += colour[i].r; sg += colour[i].g; sb += colour[i].b; n += 1 }
            let fill: (Double, Double, Double) = n > 0
                ? (sr / Double(n), sg / Double(n), sb / Double(n)) : (128, 128, 128)
            for i in 0..<count where !known[i] { colour[i] = fill }
        }

        // 4. Emit as an 8-bit DeviceRGB image, no alpha (24 bpp).
        var bytes = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count {
            bytes[i * 3]     = UInt8(clamping: Int(colour[i].r.rounded()))
            bytes[i * 3 + 1] = UInt8(clamping: Int(colour[i].g.rounded()))
            bytes[i * 3 + 2] = UInt8(clamping: Int(colour[i].b.rounded()))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: blocksWide, height: blocksHigh, bitsPerComponent: 8, bitsPerPixel: 24,
                       bytesPerRow: blocksWide * 3, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Whether the mask marks (x, y) as ink — BilevelBitmap's convention: MSB first, bit 0 = ink.
    private static func maskIsInk(_ mask: BilevelBitmap, _ x: Int, _ y: Int) -> Bool {
        mask.bits[y * mask.bytesPerRow + x / 8] & (UInt8(0x80) >> UInt8(x % 8)) == 0
    }

    /// 8-bit RGB copy of the image, row-compacted to 4 bytes/px (RGBX), mirroring greyBuffer: the
    /// only other place raw CGImage rows are touched, and padding is never copied in (C1).
    struct RGBBuffer { let width: Int; let height: Int; let pixels: [UInt8] }
    static func rgbBuffer(of image: CGImage) -> RGBBuffer? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = ctx.bytesPerRow
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {                       // row-addressed copy; padding never read (C1)
            pixels.withUnsafeMutableBufferPointer { buf in
                memcpy(buf.baseAddress! + y * w * 4, base + y * stride, w * 4)
            }
        }
        return RGBBuffer(width: w, height: h, pixels: pixels)
    }

    /// 8-bit grey copy of the image, row-compacted (pixels[y*width + x]) — the ONE place raw
    /// CGImage rows are touched; everything downstream indexes the compact buffer (C1).
    struct GreyBuffer { let width: Int; let height: Int; let pixels: [UInt8] }
    static func greyBuffer(of image: CGImage) -> GreyBuffer? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = ctx.bytesPerRow
        var pixels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {                       // row-addressed copy; padding never read (C1)
            pixels.withUnsafeMutableBufferPointer { buf in
                memcpy(buf.baseAddress! + y * w, base + y * stride, w)
            }
        }
        return GreyBuffer(width: w, height: h, pixels: pixels)
    }

    /// Drop ink components below `minComponentArea` (4-connectivity flood fill, iterative
    /// explicit stack — recursion would overflow on megapixel buffers). Each unvisited ink
    /// pixel seeds a component collected into a reusable stack; if it is too small, the
    /// collected pixels are cleared.
    static func removeSpecks(_ ink: inout [Bool], width: Int, height: Int) {
        var visited = [Bool](repeating: false, count: width * height)
        var stack = [Int]()                    // reused across components
        var component = [Int]()                // indices in the current component
        for start in 0..<(width * height) where ink[start] && !visited[start] {
            stack.removeAll(keepingCapacity: true)
            component.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            while let p = stack.popLast() {
                component.append(p)
                let x = p % width, y = p / width
                if x > 0 { neighbour(p - 1, ink, &visited, &stack) }
                if x < width - 1 { neighbour(p + 1, ink, &visited, &stack) }
                if y > 0 { neighbour(p - width, ink, &visited, &stack) }
                if y < height - 1 { neighbour(p + width, ink, &visited, &stack) }
            }
            if component.count < minComponentArea {
                for p in component { ink[p] = false }
            }
        }
    }

    /// Enqueue an unvisited ink neighbour, marking it visited on the way in so it is queued once.
    private static func neighbour(_ p: Int, _ ink: [Bool],
                                  _ visited: inout [Bool], _ stack: inout [Int]) {
        if ink[p] && !visited[p] {
            visited[p] = true
            stack.append(p)
        }
    }

    /// Pack to BilevelBitmap's convention: 1 bit/px, MSB first, 0 = black (ink). Rows are padded
    /// to whole bytes; each byte starts white (0xFF) and an ink bit is cleared.
    static func packBits(_ ink: [Bool], width: Int, height: Int) -> BilevelBitmap {
        let bytesPerRow = (width + 7) / 8
        var bits = [UInt8](repeating: 0xFF, count: bytesPerRow * height)
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width where ink[y * width + x] {
                bits[rowStart + x / 8] &= ~(UInt8(0x80) >> UInt8(x % 8))
            }
        }
        return BilevelBitmap(width: width, height: height, bytesPerRow: bytesPerRow, bits: bits)
    }
}
