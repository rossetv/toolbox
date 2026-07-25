// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation

/// Builds a PDF from Mixed Raster Content pages: a smooth colour background overlaid by a
/// text-coloured foreground that a bilevel soft mask lets through only where the ink is.
///
/// A page is either a plain DCT-encoded image (the fallback when segmentation declined, R5) or an
/// MRC triple — background + foreground + CCITT mask. As with `BilevelPDFComposer`, the output is
/// a *new* document, so this composes classic-xref bytes by hand rather than going through
/// `PDFWriter`. The load-bearing invariant (I1, proven in the spike): every soft-mask stream's
/// ColorSpace must be the literal `/DeviceGray` — CoreGraphics silently renders ghost text on any
/// other space, so the mask dict is fixed, never derived from the encoder.
enum MRCComposer {

    /// A DCT-encoded (JPEG) DeviceRGB layer, ready to embed as an image XObject with
    /// `/Filter /DCTDecode`.
    struct JPEGImage {
        let data: Data
        let width: Int
        let height: Int
    }

    enum PageContent {
        /// Fallback page (R5): one full-bleed JPEG, no masking.
        case jpeg(JPEGImage)
        /// MRC page: `background` painted first, `foreground` over it, gated by `mask`.
        case mrc(background: JPEGImage, foreground: JPEGImage, mask: CCITTEncoder.Encoded)
    }

    struct Page {
        let content: PageContent
        /// Page size in PDF points (1/72"), the source page's **displayed** size — width/height
        /// already swapped at 90°/270°. The layers are rendered upright (`PDFService.render` bakes
        /// `/Rotate` into the pixels), so the composed page carries no `/Rotate`: its MediaBox is
        /// these displayed dimensions and a viewer shows it the right way up. Re-stamping the
        /// source `/Rotate` here would turn the already-upright page a second time (I2).
        let size: CGSize
    }

    enum Failure: Error {
        case noPages
        /// A page whose size is non-finite or not strictly positive. Clamping it (the rejected
        /// alternative) silently changes the geometry instead of catching the degenerate input.
        case invalidPageSize(CGSize)
    }

    static func compose(pages: [Page]) throws -> Data {
        guard !pages.isEmpty else { throw Failure.noPages }

        // A jpeg page is 3 objects (page, content, image); an mrc page is 5 (page, content,
        // background, foreground, mask). Object numbers can't use a fixed stride across a mixed
        // document, so precompute each page's dict-object number for the Kids array.
        var pageObjectNumbers: [Int] = []
        var nextObject = 3                         // 1 = catalog, 2 = page tree
        for page in pages {
            pageObjectNumbers.append(nextObject)
            switch page.content {
            case .jpeg: nextObject += 3
            case .mrc: nextObject += 5
            }
        }

        var out = Data()
        var offsets: [Int] = [0]                   // object 0 is the free head
        func append(_ string: String) { out.append(Data(string.utf8)) }
        func appendData(_ data: Data) { out.append(data) }
        func beginObject(_ number: Int) {
            offsets.append(out.count)
            append("\(number) 0 obj\n")
        }

        append("%PDF-1.7\n")
        // A binary comment marks the file as containing binary data, per the PDF convention.
        out.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))

        let kids = pageObjectNumbers.map { "\($0) 0 R" }.joined(separator: " ")

        beginObject(1)
        append("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

        beginObject(2)
        append("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>\nendobj\n")

        for (index, page) in pages.enumerated() {
            let pageObject = pageObjectNumbers[index]

            // Reject a degenerate or non-finite page size rather than clamping it: clamping a
            // tiny page up to 1pt is itself a silent geometry change, and `max(1, .infinity)` is
            // still infinity, which formats as the non-PDF token "inf". Emitted as reals so
            // non-integer sizes (A4 is 595.276 x 841.89pt) survive intact.
            guard page.size.width.isFinite, page.size.height.isFinite,
                  page.size.width > 0, page.size.height > 0 else {
                throw Failure.invalidPageSize(page.size)
            }
            let width = Self.number(page.size.width)
            let height = Self.number(page.size.height)

            switch page.content {
            case .jpeg(let image):
                let contentObject = pageObject + 1
                let imageObject = pageObject + 2

                beginObject(pageObject)
                append("""
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] \
                /Resources << /XObject << /Im0 \(imageObject) 0 R >> >> \
                /Contents \(contentObject) 0 R >>
                endobj

                """)

                let content = "q\n\(width) 0 0 \(height) 0 0 cm\n/Im0 Do\nQ\n"
                beginObject(contentObject)
                append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream\nendobj\n")

                beginObject(imageObject)
                appendJPEGXObject(image, smask: nil, append: append, appendData: appendData)

            case .mrc(let background, let foreground, let mask):
                let contentObject = pageObject + 1
                let bgObject = pageObject + 2
                let fgObject = pageObject + 3
                let maskObject = pageObject + 4

                beginObject(pageObject)
                append("""
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] \
                /Resources << /XObject << /Bg \(bgObject) 0 R /Fg \(fgObject) 0 R >> >> \
                /Contents \(contentObject) 0 R >>
                endobj

                """)

                // Background first, foreground over it; both full-bleed on the same unit square.
                let content = """
                q\n\(width) 0 0 \(height) 0 0 cm\n/Bg Do\nQ\n\
                q\n\(width) 0 0 \(height) 0 0 cm\n/Fg Do\nQ\n
                """
                beginObject(contentObject)
                append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream\nendobj\n")

                beginObject(bgObject)
                appendJPEGXObject(background, smask: nil, append: append, appendData: appendData)

                beginObject(fgObject)
                appendJPEGXObject(foreground, smask: maskObject, append: append, appendData: appendData)

                beginObject(maskObject)
                appendMaskXObject(mask, append: append, appendData: appendData)
            }
        }

        let objectCount = offsets.count            // includes the free object 0
        let startxref = out.count
        append("xref\n0 \(objectCount)\n")
        append("0000000000 65535 f \n")
        for offset in offsets.dropFirst() {
            append(xrefEntry(offset: offset))
        }
        append("trailer\n<< /Size \(objectCount) /Root 1 0 R >>\nstartxref\n\(startxref)\n%%EOF\n")
        return out
    }

    /// A single 20-byte classic-xref entry for an in-use object. `%ld` (not `%d`) is required:
    /// `%d` truncates the 64-bit offset to 32 bits, corrupting the entry for files over 2 GiB.
    static func xrefEntry(offset: Int) -> String {
        String(format: "%010ld 00000 n \n", offset)
    }

    /// A DeviceRGB DCTDecode image XObject, optionally gated by a soft mask (`/SMask N 0 R`).
    private static func appendJPEGXObject(_ image: JPEGImage, smask: Int?,
                                          append: (String) -> Void, appendData: (Data) -> Void) {
        let smaskEntry = smask.map { "/SMask \($0) 0 R " } ?? ""
        append("""
        << /Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) \
        /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode \(smaskEntry)\
        /Length \(image.data.count) >>
        stream

        """)
        appendData(image.data)
        append("\nendstream\nendobj\n")
    }

    /// The soft-mask XObject. ColorSpace is the literal `/DeviceGray` (I1 — CoreGraphics renders
    /// ghost text on anything else). `/BlackIs1` mirrors the encoder's actual flag.
    ///
    /// `/Decode [1 0]` inverts the decoded samples so mask ink maps to soft-mask opacity 1
    /// (foreground visible) and paper to 0 (background shows through). With the encoder's
    /// WhiteIsZero output (`blackIs1 == false`) a decoded black-ink sample is 0, which the default
    /// SMask reads as *transparent* — the wrong way round; `[1 0]` flips it. Empirically pinned by
    /// `MRCComposerTests.testMaskPolarity` (render red over a half-ink mask, assert red lands only
    /// in the ink half): `[0 1]` was measured to invert it (ink→white, paper→red), the only
    /// trustworthy way to fix CCITT polarity.
    ///
    /// This fixed `[1 0]` is correct *because* `BlackIs1` and `Decode` are two independent
    /// inversion stages and `CCITTEncoder` invariantly yields `blackIs1 == false` (ImageIO's G4
    /// output is always WhiteIsZero). Were the encoder ever to emit `blackIs1 == true`, a fixed
    /// `[1 0]` would double-invert the mask — the exact ghost/inverted-text failure I1 guards.
    /// Deriving `Decode` from `blackIs1` is the robust generalisation, but its `true` branch would
    /// be dead and untested against this encoder, so the invariant is documented instead.
    private static func appendMaskXObject(_ mask: CCITTEncoder.Encoded,
                                          append: (String) -> Void, appendData: (Data) -> Void) {
        append("""
        << /Type /XObject /Subtype /Image /Width \(mask.width) /Height \(mask.height) \
        /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode \
        /DecodeParms << /K -1 /Columns \(mask.width) /Rows \(mask.height) \
        /BlackIs1 \(mask.blackIs1 ? "true" : "false") >> /Decode [1 0] \
        /Length \(mask.data.count) >>
        stream

        """)
        appendData(mask.data)
        append("\nendstream\nendobj\n")
    }

    /// A PDF real, written with an explicitly nil locale: the format requires "." as the decimal
    /// separator, which a locale-aware conversion would not guarantee.
    private static func number(_ value: CGFloat) -> String {
        String(format: "%.4f", locale: nil, Double(value))
    }
}
