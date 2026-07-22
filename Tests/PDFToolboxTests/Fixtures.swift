// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation
@testable import PDFToolbox

/// Synthetic PDF generators — all content is produced in-process via CoreGraphics/PDFKit
/// with a deterministic PRNG. **No personal documents, paths, names, or contents ever
/// enter the test suite.** Extended across Phase 0 (image here in 0.2; the rest in 0.3).
enum Fixtures {
    enum FixtureError: Error { case contextCreation, imageRender }

    /// US Letter at 72 pt/in.
    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    /// Deterministic xorshift PRNG — reproducible fixtures (no `Date`/`arc4random` dependence).
    struct RNG {
        var seed: UInt64
        init(seed: UInt64 = 0x9E3779B97F4A7C15) { self.seed = seed }
        mutating func next() -> Double {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Double(seed >> 11) / Double(1 << 53)
        }
    }

    /// A fresh, unique temp file URL (canonical). Each call gets its own directory so
    /// concurrent tests never collide.
    static func uniqueURL(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftoolbox-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.canonical.appendingPathComponent(name)
    }

    /// One Letter page carrying a ~300 dpi photo-like continuous-tone image (gradient +
    /// translucent blobs + fine grain) — several MB, genuinely shrinks under `/ebook`
    /// downsampling. Mirrors the spike's proven generator; grain is written directly into
    /// the pixel buffer (fast, deterministic, high-entropy) rather than via many draw calls.
    static func imagePDF() throws -> URL {
        let pxW = 2400, pxH = 3150
        let bytesPerRow = pxW * 4
        let byteCount = bytesPerRow * pxH
        let buf = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        defer { buf.deallocate() }
        memset(buf, 0, byteCount)

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let bmp = CGContext(data: buf, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FixtureError.contextCreation
        }
        var rng = RNG()

        // Vertical gradient background (continuous tone — a realistic photo baseline).
        for row in 0..<pxH {
            let t = Double(row) / Double(pxH)
            bmp.setFillColor(CGColor(red: CGFloat(0.2 + 0.6 * t),
                                     green: CGFloat(0.4 + 0.3 * t),
                                     blue: CGFloat(0.7 - 0.4 * t), alpha: 1))
            bmp.fill(CGRect(x: 0, y: row, width: pxW, height: 1))
        }
        // Translucent random blobs → photo-like continuous tone that DCT handles well.
        for _ in 0..<1200 {
            let r = 20 + rng.next() * 180
            bmp.setFillColor(CGColor(red: rng.next(), green: rng.next(), blue: rng.next(),
                                     alpha: 0.25 + rng.next() * 0.35))
            bmp.fillEllipse(in: CGRect(x: rng.next() * Double(pxW) - r,
                                       y: rng.next() * Double(pxH) - r,
                                       width: r * 2, height: r * 2))
        }
        // Fine per-byte grain straight into the buffer — high-frequency noise that defeats
        // trivial RLE/flate, so the original PDF is genuinely large and DCT-compressible.
        let bytes = buf.assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i < byteCount {
            bytes[i] = UInt8(rng.next() * 255.0)
            i += 7
        }
        guard let img = bmp.makeImage() else { throw FixtureError.imageRender }

        let url = try uniqueURL("image.pdf")
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        ctx.beginPDFPage(nil)
        ctx.draw(img, in: CGRect(x: 18, y: 18, width: 576, height: 756)) // 8×10.5in @ 300dpi
        ctx.endPDFPage()
        ctx.closePDF()
        return url.canonical
    }
}
