// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation

/// The MRC split: Sauvola-class local-threshold text mask (this file), plus fg/bg colour
/// layers (Task 11). A port of the reference pipeline's approach, calibrated against the
/// reference tool's outputs at the M2 gate — the spike proved the approach, not this port.
enum MRCSegmenter {

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
