// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import CoreText
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

    /// Born-digital vector text, `pages` pages — extractable text, classifies `.bornDigital`.
    static func bornDigitalPDF(pages: Int = 3) throws -> URL {
        let url = try uniqueURL("born-digital.pdf")
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for page in 1...max(1, pages) {
            ctx.beginPDFPage(nil)
            var y: CGFloat = 748
            for line in 0..<14 {
                let string = "Page \(page), line \(line): The quick brown fox jumps over the lazy dog. " +
                             "Born-digital vector text — 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ."
                drawText(string, in: ctx, at: CGPoint(x: 40, y: y), font: font)
                y -= 16
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url.canonical
    }

    /// One page whose only content is a rasterised near-two-tone image (black shapes/text on
    /// white) — no text layer, classifies `.scanBilevel`.
    static func bilevelPDF() throws -> URL {
        // Sparse black-on-white content with generous margins — overwhelmingly near-two-tone
        // even after the embedded image is JPEG-encoded (dense text greys the edges and drops
        // below the near-bilevel threshold).
        let image = renderBitmap(width: 1700, height: 2200) { ctx, _ in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1700, height: 2200))
            let font = CTFontCreateWithName("Helvetica" as CFString, 44, nil)
            var y: CGFloat = 1600
            for line in 0..<12 {
                drawText("Bilevel scan line \(line).",
                         in: ctx, at: CGPoint(x: 150, y: y), font: font, color: .black)
                y -= 70
            }
        }
        return try embedImagePDF(image, name: "bilevel.pdf")
    }

    /// One page whose only content is a rasterised image containing the rendered words
    /// "HELLO WORLD" — no text layer, for OCR tests (Track B).
    static func textImagePDF() throws -> URL {
        let image = renderBitmap(width: 1700, height: 600) { ctx, _ in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1700, height: 600))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 160, nil)
            drawText("HELLO WORLD", in: ctx, at: CGPoint(x: 120, y: 240), font: font, color: .black)
        }
        return try embedImagePDF(image, name: "text-image.pdf")
    }

    /// A user-password-protected PDF — opens locked (`PDFDocument.isLocked == true`).
    static func encryptedPDF(userPassword: String = "secret") throws -> URL {
        let url = try uniqueURL("encrypted.pdf")
        let auxInfo: [CFString: Any] = [
            kCGPDFContextUserPassword: userPassword,
            kCGPDFContextOwnerPassword: userPassword + "-owner",
        ]
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, auxInfo as CFDictionary) else {
            throw FixtureError.contextCreation
        }
        ctx.beginPDFPage(nil)
        drawText("Encrypted.", in: ctx, at: CGPoint(x: 72, y: 700),
                 font: CTFontCreateWithName("Helvetica" as CFString, 24, nil))
        ctx.endPDFPage()
        ctx.closePDF()
        return url.canonical
    }

    /// A truncated/garbage file that is not a readable PDF (`PDFDocument(url:)` returns nil).
    static func corruptPDF() throws -> URL {
        let url = try uniqueURL("corrupt.pdf")
        let bytes = "%PDF-1.4\n%\u{00}\u{00} truncated garbage \u{FF}\u{FE} not a real xref".data(using: .isoLatin1)!
        try bytes.write(to: url)
        return url.canonical
    }

    // MARK: drawing helpers

    private enum InkColour { case black, white }

    private static func drawText(_ string: String, in ctx: CGContext, at point: CGPoint,
                                 font: CTFont, color: InkColour = .black) {
        let cg = color == .black
            ? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: cg]
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)!
        let ctLine = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = point
        CTLineDraw(ctLine, ctx)
    }

    private static func renderBitmap(width: Int, height: Int,
                                     draw: (CGContext, Fixtures.RNG) -> Void) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        draw(ctx, RNG())
        return ctx.makeImage()!
    }

    private static func embedImagePDF(_ image: CGImage, name: String) throws -> URL {
        let url = try uniqueURL(name)
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: CGRect(x: 18, y: 18, width: 576, height: 756))
        ctx.endPDFPage()
        ctx.closePDF()
        return url.canonical
    }
}
