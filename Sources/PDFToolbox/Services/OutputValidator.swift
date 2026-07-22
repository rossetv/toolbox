// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation
import PDFKit

/// Re-validates a compressed/OCR'd output before it is called done (spec §5.4). Asserts the
/// output opens, has the **same page count** as the input, and that N sample pages **render
/// without error and are non-blank** — catching blank-page / stream corruption that "it opens"
/// alone would miss. It does **not** pixel-compare against the input: lossy compression
/// legitimately changes appearance.
struct OutputValidator {
    let service: PDFService

    init(service: PDFService = PDFService()) {
        self.service = service
    }

    func validate(input: URL, output: URL, samplePages: Int = 3) throws -> Bool {
        guard let inputDoc = PDFDocument(url: input),
              let outputDoc = PDFDocument(url: output) else {
            return false
        }
        guard outputDoc.pageCount > 0, outputDoc.pageCount == inputDoc.pageCount else {
            return false
        }

        let indices = PDFService.sampleIndices(count: outputDoc.pageCount,
                                               sample: min(outputDoc.pageCount, samplePages))
        for i in indices {
            guard let page = outputDoc.page(at: i) else { return false }
            let image = try service.render(page, maxDimension: 800)   // per-page render/release
            if Self.isBlank(image) { return false }
        }
        return true
    }

    /// A page is blank when essentially every sampled pixel is near-white (no rendered content).
    private static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data else { return true }
        let length = CFDataGetLength(data)
        guard let ptr = CFDataGetBytePtr(data), length > 0 else { return true }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        guard bytesPerPixel >= 3 else { return true }

        var nonWhite = 0
        var total = 0
        let pixelCount = length / bytesPerPixel
        let stride = max(1, pixelCount / 6000) * bytesPerPixel
        var offset = 0
        while offset + 2 < length {
            let r = Int(ptr[offset]), g = Int(ptr[offset + 1]), b = Int(ptr[offset + 2])
            if r < 245 || g < 245 || b < 245 { nonWhite += 1 }
            total += 1
            offset += stride
        }
        // Blank if almost no pixels carry ink. The floor sits above page-border anti-aliasing
        // (~1% for a truly empty page) and well below any real content (a 14-line text page is
        // ~7%), so a rendered-blank / corrupt page is caught without rejecting sparse content.
        return total > 0 && Double(nonWhite) / Double(total) < 0.03
    }
}
