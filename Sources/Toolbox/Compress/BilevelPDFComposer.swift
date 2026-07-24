// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation

/// Builds a PDF whose pages are CCITT G4 image XObjects.
///
/// Rung 2 replaces a scanned page with a binarised, fax-encoded image, so the output is a *new*
/// document rather than an edit of the original — which is why this composes bytes directly
/// instead of going through `PDFWriter`'s incremental-update path. The structure is deliberately
/// plain: catalog, page tree, and per page a content stream that paints one full-bleed image.
enum BilevelPDFComposer {

    struct Page {
        let image: CCITTEncoder.Encoded
        /// Page size in PDF points (1/72"), the source page's **displayed** size — width/height
        /// already swapped at 90°/270°. The bitmap is rendered upright (`PDFService.render` bakes
        /// `/Rotate` into the pixels), so the composed page carries no `/Rotate`: its MediaBox is
        /// these displayed dimensions and a viewer shows it the right way up. Re-stamping the
        /// source `/Rotate` here would turn the already-upright scan a second time.
        let size: CGSize
    }

    enum Failure: Error {
        case noPages
        /// A page whose size is non-finite or not strictly positive — clamping it (the old
        /// behaviour) silently changed the geometry instead of catching the degenerate input.
        case invalidPageSize(CGSize)
    }

    static func compose(pages: [Page]) throws -> Data {
        guard !pages.isEmpty else { throw Failure.noPages }

        var out = Data()
        var offsets: [Int] = [0]          // object 0 is the free head
        func append(_ string: String) { out.append(Data(string.utf8)) }
        func beginObject(_ number: Int) {
            offsets.append(out.count)
            append("\(number) 0 obj\n")
        }

        append("%PDF-1.7\n")
        // A binary comment marks the file as containing binary data, per the PDF convention.
        out.append(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))

        // 1 = catalog, 2 = page tree, then three objects per page.
        let firstPageObject = 3
        let kids = (0..<pages.count).map { "\(firstPageObject + $0 * 3) 0 R" }.joined(separator: " ")

        beginObject(1)
        append("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

        beginObject(2)
        append("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>\nendobj\n")

        for (index, page) in pages.enumerated() {
            let pageObject = firstPageObject + index * 3
            let contentObject = pageObject + 1
            let imageObject = pageObject + 2

            // Reject a degenerate or non-finite page size rather than clamping it: clamping a
            // tiny page up to 1pt is itself a silent geometry change (a 0.5×0.5pt page would
            // become 1×1 — a 2× stretch), and `max(1, .infinity)` is still infinity, which
            // formats as the non-PDF token "inf". Emitted as reals rather than rounded to whole
            // points: A4 is 595.276 x 841.89pt, and rounding would ship a page up to half a
            // point off the original with the image stretched to match — a silent geometry
            // change on a path that promises not to make one.
            guard page.size.width.isFinite, page.size.height.isFinite,
                  page.size.width > 0, page.size.height > 0 else {
                throw Failure.invalidPageSize(page.size)
            }
            let width = Self.number(page.size.width)
            let height = Self.number(page.size.height)

            beginObject(pageObject)
            append("""
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] \
            /Resources << /XObject << /Im0 \(imageObject) 0 R >> >> \
            /Contents \(contentObject) 0 R >>
            endobj

            """)

            // Paint the image across the whole page.
            let content = "q\n\(width) 0 0 \(height) 0 0 cm\n/Im0 Do\nQ\n"
            beginObject(contentObject)
            append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream\nendobj\n")

            beginObject(imageObject)
            append("""
            << /Type /XObject /Subtype /Image /Width \(page.image.width) /Height \(page.image.height) \
            /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode \
            /DecodeParms << /K -1 /Columns \(page.image.width) /Rows \(page.image.height) \
            /BlackIs1 \(page.image.blackIs1 ? "true" : "false") >> /Length \(page.image.data.count) >>
            stream

            """)
            out.append(page.image.data)
            append("\nendstream\nendobj\n")
        }

        let objectCount = offsets.count            // includes the free object 0
        let startxref = out.count
        append("xref\n0 \(objectCount)\n")
        append("0000000000 65535 f \n")
        for offset in offsets.dropFirst() {
            append(String(format: "%010d 00000 n \n", offset))
        }
        append("trailer\n<< /Size \(objectCount) /Root 1 0 R >>\nstartxref\n\(startxref)\n%%EOF\n")
        return out
    }

    /// A PDF real, written with an explicitly nil locale: the format requires "." as the decimal
    /// separator, which a locale-aware conversion would not guarantee.
    private static func number(_ value: CGFloat) -> String {
        String(format: "%.4f", locale: nil, Double(value))
    }
}
