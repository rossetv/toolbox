// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import PDFKit
import XCTest
@testable import PDFToolbox

final class BilevelPDFComposerTests: XCTestCase {

    /// Black bars on white, covering a known fraction of the page.
    private func barsImage(width: Int = 1200, height: Int = 1600) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        for line in 0..<30 {
            context.fill(CGRect(x: 100, y: Double(height) - 150 - Double(line) * 45,
                                width: Double(width) - 200, height: 14))
        }
        return context.makeImage()!
    }

    /// Fraction of sampled pixels that are dark, from a rendered page.
    private func inkRatio(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return 0 }
        let length = CFDataGetLength(data)
        let bpp = max(1, image.bitsPerPixel / 8)
        // Handles both 8-bit grey sources (1 byte/pixel) and rendered RGBA pages.
        guard bpp >= 1, image.width > 0, image.height > 0 else { return 0 }
        var dark = 0, total = 0
        var y = 0
        let step = max(1, Int((Double(image.width * image.height) / 5000.0).squareRoot()))
        while y < image.height {
            var x = 0
            while x < image.width {
                let o = y * image.bytesPerRow + x * bpp
                guard o + 2 < length else { break }
                if Int(ptr[o]) < 128 { dark += 1 }
                total += 1
                x += step
            }
            y += step
        }
        return total > 0 ? Double(dark) / Double(total) : 0
    }

    func testComposesAValidPDFWithTheExpectedGeometry() throws {
        let encoded = try CCITTEncoder.encode(barsImage())
        let data = try BilevelPDFComposer.compose(pages: [
            .init(image: encoded, size: CGSize(width: 612, height: 792)),
            .init(image: encoded, size: CGSize(width: 612, height: 792)),
        ])

        let document = try XCTUnwrap(PDFDocument(data: data), "composed bytes must open as a PDF")
        XCTAssertEqual(document.pageCount, 2)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 612, accuracy: 1)
        XCTAssertEqual(bounds.height, 792, accuracy: 1)
    }

    /// The polarity check. An inverted `/BlackIs1` still produces a perfectly valid PDF — it just
    /// renders as white-on-black. Only rendering the result and comparing ink against the source
    /// catches that, which is why this test exists rather than an assertion about the flag.
    func testRenderedPageIsNotInverted() throws {
        let source = barsImage()
        let sourceInk = inkRatio(source)
        XCTAssertGreaterThan(sourceInk, 0.05, "fixture should carry real ink")
        XCTAssertLessThan(sourceInk, 0.5, "fixture should be mostly white paper")

        let encoded = try CCITTEncoder.encode(source)
        let data = try BilevelPDFComposer.compose(pages: [
            .init(image: encoded, size: CGSize(width: 612, height: 792)),
        ])
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let rendered = try PDFService().render(page, maxDimension: 800)

        let renderedInk = inkRatio(rendered)
        XCTAssertLessThan(renderedInk, 0.5,
                          "page rendered mostly dark — /BlackIs1 polarity is inverted (ink \(renderedInk))")
        XCTAssertGreaterThan(renderedInk, 0.01, "page rendered blank — content was lost")
    }
}
