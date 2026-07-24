// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import Compression
import CoreGraphics
import CoreText
import Foundation
import PDFKit
@testable import Toolbox

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
            .appendingPathComponent("toolbox-fixtures-\(UUID().uuidString)", isDirectory: true)
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
    /// `lines` scales the per-page content: fewer lines → a smaller file with proportionally
    /// less ink, letting a test build a "compressed" counterpart of the default fixture that
    /// still passes `OutputValidator`'s retained-ink comparison.
    static func bornDigitalPDF(pages: Int = 3, lines: Int = 14) throws -> URL {
        let url = try uniqueURL("born-digital.pdf")
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for page in 1...max(1, pages) {
            ctx.beginPDFPage(nil)
            var y: CGFloat = 748
            for line in 0..<max(1, lines) {
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

    /// One page carrying an **8-bit greyscale** scan that is *visually* two-tone: dark ink on
    /// light paper, with realistic paper/ink grain so the image is genuinely continuous-tone and
    /// not secretly 1-bit.
    ///
    /// This is the case Rung 1 cannot help with and Rung 2 exists for (spec §5.1): Ghostscript's
    /// `MonoImage*` settings only reach images that are *already* 1-bit, so a greyscale scan that
    /// looks black-and-white is treated as a grey image and can come out **larger** than it went
    /// in. Binarising first, then encoding CCITT G4, is where the large win is.
    ///
    /// The grain is kept well clear of the middle of the range (paper 232…250, ink 6…26) so the
    /// Otsu threshold lands in an empty valley and binarisation does not produce salt-and-pepper.
    static func greyscaleScanPDF(pages: Int = 1) throws -> URL {
        let url = try uniqueURL("greyscale-scan.pdf")
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        var rng = RNG()
        for page in 1...max(1, pages) {
            let pxW = 1700, pxH = 2200
            guard let grey = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw FixtureError.contextCreation
            }
            grey.setFillColor(CGColor(gray: 0.95, alpha: 1))
            grey.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
            let font = CTFontCreateWithName("Helvetica" as CFString, 46, nil)
            var y: CGFloat = 2000
            for line in 0..<22 {
                drawText("Page \(page) greyscale scan line \(line) — 0123456789.",
                         in: grey, at: CGPoint(x: 150, y: y), font: font, color: .black)
                y -= 84
            }
            guard let image = grey.makeImage(), let provider = image.dataProvider,
                  let raw = provider.data, let base = CFDataGetBytePtr(raw) else {
                throw FixtureError.imageRender
            }
            // Re-emit the rendered page with per-pixel grain, so the embedded image is a real
            // 8-bit contone scan rather than two exact values a codec can trivially collapse.
            let rowBytes = image.bytesPerRow, length = CFDataGetLength(raw)
            var grained = [UInt8](repeating: 0, count: length)
            for i in 0..<length {
                let v = Int(base[i])
                grained[i] = v > 127 ? UInt8(232 + Int(rng.next() * 18))    // paper
                                     : UInt8(6 + Int(rng.next() * 20))     // ink
            }
            guard let grainProvider = CGDataProvider(data: Data(grained) as CFData),
                  let scan = CGImage(width: pxW, height: pxH, bitsPerComponent: 8, bitsPerPixel: 8,
                                     bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                     provider: grainProvider, decode: nil,
                                     shouldInterpolate: false, intent: .defaultIntent) else {
                throw FixtureError.imageRender
            }
            ctx.beginPDFPage(nil)
            ctx.draw(scan, in: CGRect(x: 18, y: 18, width: 576, height: 756))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url.canonical
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

    /// `pages` empty white pages. Two uses: the `OutputValidator` blank-page check, and the
    /// no-gain path — gs's `pdfwrite` structure/metadata makes a blank page *larger* than the
    /// compact CoreGraphics original (verified), so compressing it yields `.noGain`.
    /// An 8-bit GREYSCALE page whose content is visually black-and-white — the case Ghostscript
    /// cannot serve, because its mono settings only apply to images that are already 1-bit.
    static func greyscaleBilevelScanPDF() throws -> URL {
        let w = 1700, h = 2200
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 0, alpha: 1)
        for line in 0..<45 {
            for word in 0..<28 {
                ctx.fill(CGRect(x: 120 + Double(word) * 54, y: 2000 - Double(line) * 44,
                                width: Double.random(in: 18...44), height: 12))
            }
        }
        let image = ctx.makeImage()!
        return try embedImagePDF(image, name: "grey-bilevel.pdf")
    }

    /// A colour text-scan lookalike: off-white tinted paper, rows of dark blue-black text-like
    /// bars with per-glyph jitter, light scanner grain. Classifies `.scanColour`; every page
    /// should pass the MRC classifier. `rotation` writes /Rotate on every page.
    static func colourTextScanPDF(pages: Int = 2, rotation: Int = 0) throws -> URL {
        let url = try uniqueURL("colour-text-scan.pdf")
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        var rng = RNG()
        for _ in 0..<max(1, pages) {
            let image = try colourTextScanBitmap(width: 1700, height: 2200, rng: &rng)
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: CGRect(x: 18, y: 18, width: 576, height: 756))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return try applyRotation(rotation, to: url)
    }

    /// A continuous-tone full-page colour image (smooth radial + linear gradients with grain —
    /// photo-class, not text). Classifies `.scanColour`; every page should FAIL the MRC
    /// classifier's envelope, and force-MRC'd pages must fail the verifier (the committed
    /// smear regression, spec §9).
    static func colourPhotoScanPDF(pages: Int = 1) throws -> URL {
        let url = try uniqueURL("colour-photo-scan.pdf")
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        var rng = RNG()
        for _ in 0..<max(1, pages) {
            let image = try colourPhotoBitmap(width: 1700, height: 2200, rng: &rng)
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: CGRect(x: 18, y: 18, width: 576, height: 756))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url.canonical
    }

    /// One document, first page text-class, second page photo-class — the mixed-eligibility
    /// e2e fixture (spec §2 "4 of 12 documents are mixed").
    static func mixedColourScanPDF() throws -> URL {
        let url = try uniqueURL("mixed-colour-scan.pdf")
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        var rng = RNG()
        let textImage = try colourTextScanBitmap(width: 1700, height: 2200, rng: &rng)
        ctx.beginPDFPage(nil)
        ctx.draw(textImage, in: CGRect(x: 18, y: 18, width: 576, height: 756))
        ctx.endPDFPage()
        let photoImage = try colourPhotoBitmap(width: 1700, height: 2200, rng: &rng)
        ctx.beginPDFPage(nil)
        ctx.draw(photoImage, in: CGRect(x: 18, y: 18, width: 576, height: 756))
        ctx.endPDFPage()
        ctx.closePDF()
        return url.canonical
    }

    /// One page's bitmap for `colourTextScanPDF`/`mixedColourScanPDF`: off-white paper, rows of
    /// dark blue-black bars standing in for text (chromatic enough to fail the near-bilevel gate
    /// — real ink is near-grey, this is deliberately blue-black), 2% grain.
    private static func colourTextScanBitmap(width: Int, height: Int, rng: inout RNG) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let bmp = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FixtureError.contextCreation
        }
        bmp.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bmp.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.35, alpha: 1))
        var y = Double(height) - 200
        while y > 100 {
            var x = 120.0
            while x < Double(width) - 60 {
                let jitterX = (rng.next() - 0.5) * 2   // ±1 px
                let jitterY = (rng.next() - 0.5) * 2
                let barWidth = 18.0 + rng.next() * 26.0
                bmp.fill(CGRect(x: x + jitterX, y: y + jitterY, width: barWidth, height: 12))
                x += barWidth + 8.0 + rng.next() * 6.0
            }
            y -= 84
        }
        return try grained(bmp, width: width, height: height, amount: 0.02, rng: &rng)
    }

    /// One page's bitmap for `colourPhotoScanPDF`/`mixedColourScanPDF`: two overlapping
    /// gradients (continuous-tone, no two-tone structure) plus 3% grain.
    private static func colourPhotoBitmap(width: Int, height: Int, rng: inout RNG) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let bmp = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FixtureError.contextCreation
        }
        let diagonal = [CGColor(red: 0.85, green: 0.35, blue: 0.2, alpha: 1),
                        CGColor(red: 0.15, green: 0.4, blue: 0.75, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: cs, colors: diagonal, locations: [0, 1]) {
            bmp.drawLinearGradient(gradient, start: .zero,
                                   end: CGPoint(x: width, y: height), options: [])
        }
        let glow = [CGColor(red: 0.95, green: 0.85, blue: 0.3, alpha: 0.6),
                   CGColor(red: 0.95, green: 0.85, blue: 0.3, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: cs, colors: glow, locations: [0, 1]) {
            let centre = CGPoint(x: width / 2, y: height / 2)
            bmp.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                                   endCenter: centre, endRadius: CGFloat(width) / 1.2, options: [])
        }
        return try grained(bmp, width: width, height: height, amount: 0.03, rng: &rng)
    }

    /// Re-emit `bmp`'s rendered pixels with per-pixel grain of `amount` (fraction of full range),
    /// same idiom as `greyscaleScanPDF` — a real 8-bit contone image, not exact flat values.
    private static func grained(_ bmp: CGContext, width: Int, height: Int,
                                amount: Double, rng: inout RNG) throws -> CGImage {
        guard let image = bmp.makeImage(), let provider = image.dataProvider,
              let raw = provider.data, let base = CFDataGetBytePtr(raw) else {
            throw FixtureError.imageRender
        }
        let length = CFDataGetLength(raw)
        var noisy = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            let noise = Int((rng.next() - 0.5) * 2 * amount * 255)
            noisy[i] = UInt8(max(0, min(255, Int(base[i]) + noise)))
        }
        guard let noisyProvider = CGDataProvider(data: Data(noisy) as CFData),
              let noisyImage = CGImage(width: width, height: height, bitsPerComponent: 8,
                                       bitsPerPixel: 32, bytesPerRow: image.bytesPerRow,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                       provider: noisyProvider, decode: nil,
                                       shouldInterpolate: false, intent: .defaultIntent) else {
            throw FixtureError.imageRender
        }
        return noisyImage
    }

    /// Set `/Rotate` on every page via PDFKit and re-save; a no-op at `rotation == 0`.
    private static func applyRotation(_ rotation: Int, to url: URL) throws -> URL {
        guard rotation != 0 else { return url.canonical }
        guard let doc = PDFDocument(url: url) else { throw FixtureError.contextCreation }
        for i in 0..<doc.pageCount {
            doc.page(at: i)?.rotation = rotation
        }
        guard doc.write(to: url) else { throw FixtureError.contextCreation }
        return url.canonical
    }

    static func blankPDF(pages: Int = 1) throws -> URL {
        let url = try uniqueURL("blank.pdf")
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        for _ in 0..<max(1, pages) {
            ctx.beginPDFPage(nil)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url.canonical
    }

    /// One page with an oversized MediaBox (3000×3000 points) carrying a small text image.
    /// The large format causes the render clamp to land below 150 dpi, triggering the
    /// minBilevelDPI floor guard in both Rung 2 and Rung 3. Used to verify the decline
    /// on insufficient effective resolution (regression test for R13).
    static func oversizedPageScanPDF() throws -> URL {
        let image = renderBitmap(width: 600, height: 600) { ctx, _ in
            ctx.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            ctx.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.35, alpha: 1))
            let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
            drawText("Oversized page", in: ctx, at: CGPoint(x: 50, y: 300), font: font)
        }
        let url = try uniqueURL("oversized-page.pdf")
        // 3000×3000 point MediaBox: balanced's bilevelDPI = 300 renders past the 5000 px
        // clamp, so the clamp dominates: effective DPI = 5000 / 3000 * 72 ≈ 120 dpi <
        // 150 minimum (minBilevelDPI) → should decline.
        var media = CGRect(x: 0, y: 0, width: 3000, height: 3000)
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: CGRect(x: 150, y: 1350, width: 600, height: 600))
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

    /// `pages` pages each carrying a distinct high-entropy 200 dpi image — tens of megabytes,
    /// for the memory-bound tests. Distinct per page so nothing is deduplicated away.
    static func repeatedImagePDF(pages: Int) throws -> URL {
        let url = try uniqueURL("large-scan.pdf")
        var media = letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw FixtureError.contextCreation
        }
        var rng = RNG()
        for _ in 0..<max(1, pages) {
            let pxW = 1600, pxH = 2100
            let bytesPerRow = pxW * 4
            let byteCount = bytesPerRow * pxH
            let buf = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
            defer { buf.deallocate() }
            let bytes = buf.assumingMemoryBound(to: UInt8.self)
            for i in 0..<byteCount { bytes[i] = UInt8(rng.next() * 255.0) }   // incompressible
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let bmp = CGContext(data: buf, width: pxW, height: pxH, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let img = bmp.makeImage() else { throw FixtureError.imageRender }
            ctx.beginPDFPage(nil)
            ctx.draw(img, in: CGRect(x: 18, y: 18, width: 576, height: 756))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url.canonical
    }

    // MARK: - Hand-authored byte-level PDFs

    /// Assemble a byte-exact PDF from hand-written object bodies, with a correct classic xref
    /// table and trailer.
    ///
    /// Every other generator here goes through CoreGraphics, which only ever emits well-formed,
    /// LF-terminated, ASCII-clean structure — which is precisely why none of them can express the
    /// inputs the writer's parser has to survive: CRLF between a key and its value, a `stream`
    /// keyword inside an ordinary word, `>>` inside a string, an implausible object number, a
    /// compressed object stream. Those are authored here, byte by byte. **Entirely synthetic —
    /// no bytes from any real document.**
    ///
    /// - Parameter eol: line terminator for the object section (the xref table keeps its own
    ///   fixed 20-byte entry format, as the specification requires).
    static func rawPDF(_ objects: [(num: Int, body: Data)],
                       root: Int,
                       name: String,
                       eol: String = "\n") throws -> URL {
        let nl = Data(eol.utf8)
        var out = Data("%PDF-1.5".utf8)
        out.append(nl)
        out.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3]))          // binary-content marker comment
        out.append(nl)

        var offsets: [Int: Int] = [:]
        for object in objects.sorted(by: { $0.num < $1.num }) {
            offsets[object.num] = out.count
            out.append(Data("\(object.num) 0 obj".utf8))
            out.append(nl)
            out.append(object.body)
            out.append(nl)
            out.append(Data("endobj".utf8))
            out.append(nl)
        }

        let highest = objects.map(\.num).max() ?? 0
        let xrefOffset = out.count
        out.append(Data("xref\n0 \(highest + 1)\n".utf8))
        out.append(Data("0000000000 65535 f \n".utf8))
        for n in 1...max(1, highest) {
            if let offset = offsets[n] {
                out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
            } else {
                out.append(Data("0000000000 65535 f \n".utf8))
            }
        }
        out.append(Data("trailer\n<< /Size \(highest + 1) /Root \(root) 0 R >>\n".utf8))
        out.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))

        let url = try uniqueURL(name)
        try out.write(to: url)
        return url.canonical
    }

    /// A PDF whose catalog, page-tree node and page all live **inside a compressed object
    /// stream**, indexed by a cross-reference stream — the modern layout the writer used to
    /// refuse outright, which excluded about a fifth of a representative corpus from OCR.
    ///
    /// Built here rather than by any framework because no Apple API emits this layout. Streams
    /// themselves cannot be packed (PDF 32000-1 §7.5.7), so the content stream, the object stream
    /// and the cross-reference stream stay top-level; objects 1–3 are packed.
    /// - Parameters:
    ///   - indirectLength: give the object stream an indirect `/Length` (`7 0 R`) — legal, and
    ///     the case where a writer that cannot resolve the reference falls back to hunting for
    ///     `endstream` inside compressed bytes that may contain it.
    ///   - padTo: pad the content stream so the file exceeds this size, pushing object offsets
    ///     past what a two-byte cross-reference field can hold.
    static func objectStreamPDF(name: String = "objstm.pdf",
                                indirectLength: Bool = false,
                                padTo: Int = 0) throws -> URL {
        let packedObjects: [(num: Int, body: String)] = [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [ 3 0 R ] /Count 1 >>"),
            (3, "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 612 792 ] "
              + "/Contents 4 0 R /Resources << >> >>"),
        ]
        // The object stream's payload: a header of `objectNumber offset` pairs, then the bodies.
        var bodies = Data()
        var header = ""
        for object in packedObjects {
            header += "\(object.num) \(bodies.count) "
            bodies.append(Data(object.body.utf8))
            bodies.append(0x20)
        }
        var payload = Data(header.utf8)
        let first = payload.count
        payload.append(bodies)
        let compressed = try zlibCompress(payload)

        var content = Data("0.9 0.9 0.9 rg 72 72 468 648 re f".utf8)
        if padTo > 0 {
            // `%` comments are legal inside a content stream and change nothing that renders.
            content.append(Data("\n% ".utf8))
            content.append(Data(repeating: 0x70, count: max(0, padTo - content.count - 512)))
        }
        var out = Data("%PDF-1.5\n".utf8)
        out.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3]))
        out.append(0x0A)

        var offsets: [Int: Int] = [:]
        func appendObject(_ num: Int, _ body: Data) {
            offsets[num] = out.count
            out.append(Data("\(num) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }

        var contentObject = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        contentObject.append(content)
        contentObject.append(Data("\nendstream".utf8))
        appendObject(4, contentObject)

        if indirectLength { appendObject(7, Data("\(compressed.count)".utf8)) }
        let lengthValue = indirectLength ? "7 0 R" : "\(compressed.count)"
        let streamHeader = "<< /Type /ObjStm /N \(packedObjects.count) /First \(first) "
            + "/Length \(lengthValue) /Filter /FlateDecode >>\nstream\n"
        var streamObject = Data(streamHeader.utf8)
        streamObject.append(compressed)
        streamObject.append(Data("\nendstream".utf8))
        appendObject(5, streamObject)

        // The cross-reference stream. /W [1 2 2]: type, then two fields. Type 2 entries name the
        // containing object stream and the index within it; type 1 entries are offset + generation.
        let xrefOffset = out.count
        offsets[6] = xrefOffset                                      // object 6 is this stream
        let highest = indirectLength ? 7 : 6
        // Field 2 carries a byte offset, so it must be wide enough for the largest one.
        var width = 2
        while width < 8, (offsets.values.max() ?? 0) >= (1 << (8 * width)) { width += 1 }

        var table = Data()
        func entry(_ type: UInt8, _ field2: Int, _ field3: Int) {
            table.append(type)
            for shift in stride(from: width - 1, through: 0, by: -1) {
                table.append(UInt8((field2 >> (8 * shift)) & 0xFF))
            }
            table.append(UInt8((field3 >> 8) & 0xFF)); table.append(UInt8(field3 & 0xFF))
        }
        entry(0, 0, 0xFFFF)                                          // object 0, free
        for i in packedObjects.indices { entry(2, 5, i) }
        for num in 4...highest { entry(1, offsets[num] ?? 0, 0) }

        let xrefHeader = "<< /Type /XRef /Size \(highest + 1) /W [ 1 \(width) 2 ] /Root 1 0 R "
            + "/Length \(table.count) >>\nstream\n"
        var xrefObject = Data(xrefHeader.utf8)
        xrefObject.append(table)
        xrefObject.append(Data("\nendstream".utf8))
        appendObject(6, xrefObject)

        out.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))

        let url = try uniqueURL(name)
        try out.write(to: url)
        return url.canonical
    }

    /// zlib (RFC 1950) — the two-byte header, raw DEFLATE, and the Adler-32 trailer that a real
    /// PDF producer emits for `/FlateDecode`.
    static func zlibCompress(_ input: Data) throws -> Data {
        var out = Data([0x78, 0x9C])
        let capacity = input.count + 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = input.withUnsafeBytes { source in
            compression_encode_buffer(destination, capacity,
                                      source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                      nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw FixtureError.contextCreation }
        out.append(destination, count: written)

        var a: UInt32 = 1, b: UInt32 = 0
        for byte in input {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = b << 16 | a
        out.append(contentsOf: [UInt8(adler >> 24 & 0xFF), UInt8(adler >> 16 & 0xFF),
                                UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
        return out
    }

    static func rawObject(_ num: Int, _ body: String) -> (num: Int, body: Data) {
        (num, Data(body.data(using: .isoLatin1) ?? Data(body.utf8)))
    }

    /// A stream object with a correct `/Length`. `extraKeys` go into the stream dictionary.
    static func rawStream(_ num: Int, body: Data, extraKeys: String = "") -> (num: Int, body: Data) {
        var out = Data("<< /Length \(body.count)\(extraKeys.isEmpty ? "" : " " + extraKeys) >>\nstream\n".utf8)
        out.append(body)
        out.append(Data("\nendstream".utf8))
        return (num, out)
    }

    /// A one-page document whose page dictionary is `pageDict`, plus a real content stream, in
    /// the given object order. The caller controls the page dictionary's exact bytes.
    ///
    /// Object numbers: 1 catalog, 2 pages, 3 page, 4 contents. `extras` are appended verbatim.
    static func rawOnePagePDF(pageDict: String,
                              name: String,
                              eol: String = "\n",
                              extras: [(num: Int, body: Data)] = []) throws -> URL {
        let content = Data("0.9 0.9 0.9 rg 72 72 468 648 re f".utf8)
        var objects: [(num: Int, body: Data)] = [
            rawObject(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            rawObject(2, "<< /Type /Pages /Kids [ 3 0 R ] /Count 1 >>"),
            rawObject(3, pageDict),
            rawStream(4, body: content),
        ]
        objects.append(contentsOf: extras)
        return try rawPDF(objects, root: 1, name: name, eol: eol)
    }

    /// The default one-page page dictionary, in the writer's own preferred spelling.
    static let plainPageDict =
        "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 612 792 ] /Contents 4 0 R /Resources << >> >>"

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
