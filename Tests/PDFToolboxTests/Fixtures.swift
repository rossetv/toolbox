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

    /// `pages` empty white pages. Two uses: the `OutputValidator` blank-page check, and the
    /// no-gain path — gs's `pdfwrite` structure/metadata makes a blank page *larger* than the
    /// compact CoreGraphics original (verified), so compressing it yields `.noGain`.
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

    /// A truncated/garbage file that is not a readable PDF (`PDFDocument(url:)` returns nil).
    static func corruptPDF() throws -> URL {
        let url = try uniqueURL("corrupt.pdf")
        let bytes = "%PDF-1.4\n%\u{00}\u{00} truncated garbage \u{FF}\u{FE} not a real xref".data(using: .isoLatin1)!
        try bytes.write(to: url)
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
