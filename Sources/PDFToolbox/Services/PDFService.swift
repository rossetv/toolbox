// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation
import PDFKit

enum PDFServiceError: Error, LocalizedError {
    case cannotOpen
    case pageOutOfRange
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .cannotOpen: return "The PDF could not be opened."
        case .pageOutOfRange: return "The requested page is out of range."
        case .renderFailed: return "The page could not be rendered."
        }
    }
}

/// PDF inspection and rasterisation. Rendering is **per-page render-then-release** (the
/// bitmap is created, used and dropped one page at a time) so a 1000-page scan never holds
/// every page in memory.
struct PDFService {

    func pageCount(_ url: URL) throws -> Int {
        guard let doc = PDFDocument(url: url) else { throw PDFServiceError.cannotOpen }
        return doc.pageCount
    }

    /// Classify by extractable-text coverage over a page sample; image-dominated docs are
    /// scans, split colour vs bilevel by rendering a sample page and testing near-two-tone.
    func classify(_ url: URL) throws -> PDFContentType {
        guard let doc = PDFDocument(url: url) else { throw PDFServiceError.cannotOpen }
        let count = doc.pageCount
        guard count > 0 else { return .bornDigital }

        let indices = Self.sampleIndices(count: count, sample: min(count, 5))
        var textPages = 0
        var imagePages = 0
        for i in indices {
            guard let page = doc.page(at: i) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= 40 { textPages += 1 } else { imagePages += 1 }
        }
        if textPages > 0 && textPages >= imagePages { return .bornDigital }

        if let first = indices.first, let page = doc.page(at: first),
           let image = try? render(page, maxDimension: 500), Self.isNearBilevel(image) {
            return .scanBilevel
        }
        return .scanColour
    }

    func pageHasText(_ url: URL, index: Int) throws -> Bool {
        guard let doc = PDFDocument(url: url) else { throw PDFServiceError.cannotOpen }
        guard index >= 0, index < doc.pageCount, let page = doc.page(at: index) else {
            throw PDFServiceError.pageOutOfRange
        }
        let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }

    /// Render a sample of `pages` pages (first, last and evenly spaced), one at a time.
    func renderSample(_ url: URL, pages: Int) throws -> [CGImage] {
        guard let doc = PDFDocument(url: url) else { throw PDFServiceError.cannotOpen }
        let count = doc.pageCount
        guard count > 0 else { return [] }
        let indices = Self.sampleIndices(count: count, sample: min(count, max(1, pages)))
        var images: [CGImage] = []
        images.reserveCapacity(indices.count)
        for i in indices {
            guard let page = doc.page(at: i) else { continue }
            images.append(try render(page, maxDimension: 1000))
        }
        return images
    }

    /// Rasterise one page onto a white background, bounded by `maxDimension` on its long edge.
    func render(_ page: PDFPage, maxDimension: CGFloat) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale = maxDimension / max(bounds.width, bounds.height, 1)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colourSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PDFServiceError.renderFailed
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { throw PDFServiceError.renderFailed }
        return image
    }

    // MARK: helpers

    static func sampleIndices(count: Int, sample: Int) -> [Int] {
        guard count > 0, sample > 0 else { return [] }
        if sample >= count { return Array(0..<count) }
        var set: Set<Int> = [0, count - 1]
        let step = max(1, count / sample)
        var i = 0
        while i < count && set.count < sample {
            set.insert(i)
            i += step
        }
        return set.sorted()
    }

    /// True when the rendered page is overwhelmingly near-black/near-white (a bilevel scan),
    /// judged on luminance, not raw bit depth (content-based, spec R2-N5).
    private static func isNearBilevel(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data else { return false }
        let length = CFDataGetLength(data)
        guard let ptr = CFDataGetBytePtr(data), length > 0 else { return false }
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        guard bytesPerPixel >= 3 else { return false }

        var extreme = 0
        var total = 0
        // Sample roughly 4000 pixels across the image.
        let pixelCount = length / bytesPerPixel
        let stride = max(1, pixelCount / 4000) * bytesPerPixel
        var offset = 0
        while offset + 2 < length {
            let r = Int(ptr[offset]), g = Int(ptr[offset + 1]), b = Int(ptr[offset + 2])
            let luminance = (r * 299 + g * 587 + b * 114) / 1000
            if luminance < 40 || luminance > 215 { extreme += 1 }
            total += 1
            offset += stride
        }
        return total > 0 && Double(extreme) / Double(total) > 0.92
    }
}
