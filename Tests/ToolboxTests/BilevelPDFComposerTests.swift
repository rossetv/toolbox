// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import PDFKit
import XCTest
@testable import Toolbox

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
        let encoded = try XCTUnwrap(CCITTEncoder.encode(barsImage()))
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

    /// The geometry regression. Most real page sizes are not whole numbers of points — A4 is
    /// 595.276 x 841.89 — so rounding the MediaBox ships a page up to half a point off the
    /// original with the image stretched to fill it. The tolerance is deliberately far below one
    /// point, because one point is precisely the error being guarded against.
    func testPreservesNonIntegerPageGeometry() throws {
        let encoded = try XCTUnwrap(CCITTEncoder.encode(barsImage()))
        let a4 = CGSize(width: 595.276, height: 841.89)
        let data = try BilevelPDFComposer.compose(pages: [.init(image: encoded, size: a4)])

        let document = try XCTUnwrap(PDFDocument(data: data))
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, a4.width, accuracy: 0.001)
        XCTAssertEqual(bounds.height, a4.height, accuracy: 0.001)
    }

    /// The polarity check. An inverted `/BlackIs1` still produces a perfectly valid PDF — it just
    /// renders as white-on-black. Only rendering the result and comparing ink against the source
    /// catches that, which is why this test exists rather than an assertion about the flag.
    func testRenderedPageIsNotInverted() throws {
        let source = barsImage()
        let sourceInk = inkRatio(source)
        XCTAssertGreaterThan(sourceInk, 0.05, "fixture should carry real ink")
        XCTAssertLessThan(sourceInk, 0.5, "fixture should be mostly white paper")

        let encoded = try XCTUnwrap(CCITTEncoder.encode(source))
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

    /// Regression: a small-but-legitimate page size must be preserved exactly, not silently
    /// clamped up to 1pt (a 0.5×0.5pt page previously composed as `MediaBox [0 0 1.0000 1.0000]`
    /// — a 2× geometry change on the very path `testPreservesNonIntegerPageGeometry` certifies
    /// to 0.001pt).
    func testSmallPositivePageSizeIsPreservedNotClamped() throws {
        let encoded = try XCTUnwrap(CCITTEncoder.encode(barsImage()))
        let tiny = CGSize(width: 0.5, height: 0.5)
        let data = try BilevelPDFComposer.compose(pages: [.init(image: encoded, size: tiny)])

        let document = try XCTUnwrap(PDFDocument(data: data))
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, tiny.width, accuracy: 0.001)
        XCTAssertEqual(bounds.height, tiny.height, accuracy: 0.001)
    }

    /// Regression: a degenerate or non-finite page size must be rejected, never clamped into a
    /// silently-distorted (or, for `.infinity`/`.nan`, non-PDF) `/MediaBox`.
    func testDegenerateOrNonFinitePageSizeIsRejected() throws {
        let encoded = try XCTUnwrap(CCITTEncoder.encode(barsImage()))
        let badSizes: [CGSize] = [
            CGSize(width: 0, height: 800),
            CGSize(width: 600, height: 0),
            CGSize(width: -5, height: 800),
            CGSize(width: CGFloat.infinity, height: 800),
            CGSize(width: CGFloat.nan, height: 800),
        ]
        for size in badSizes {
            XCTAssertThrowsError(
                try BilevelPDFComposer.compose(pages: [.init(image: encoded, size: size)]),
                "size \(size) must be rejected, not silently clamped"
            )
        }
    }

    // MARK: - BilevelScan.binarise fails closed on a short data provider
    //
    // Placed here (not a dedicated BilevelScanTests.swift) — `BilevelScan` is `@testable`-visible
    // from any file in this target.

    /// Regression: a data provider shorter than `bytesPerRow * height` must make `binarise`
    /// return `nil`, not a bitmap whose unread rows were silently left white. Built by hand
    /// (rather than via `CGContext`) because CoreGraphics itself never produces a short buffer —
    /// this proves the *contract*, not a reachable CoreGraphics scenario.
    /// `binarise` guards `length >= rowBytes * height` before walking the buffer, so a short
    /// provider can never leave part of a page silently white. That guard is defence in depth
    /// rather than a reachable path: CoreGraphics refuses outright to construct an image whose
    /// data provider is shorter than the geometry it declares, so the truncated image cannot be
    /// handed to us in the first place.
    ///
    /// This asserts that platform behaviour instead of leaving it as a claim in a comment. If a
    /// future OS ever starts allowing such an image, this test fails and the guard stops being
    /// merely defensive — which is exactly when someone needs to know.
    func testCoreGraphicsRefusesAnImageShorterThanItsDeclaredGeometry() throws {
        let width = 10, height = 10, bytesPerPixel = 4
        let rowBytes = width * bytesPerPixel
        let shortData = Data(repeating: 0x00, count: rowBytes * 2)   // only 2 of 10 rows backed
        let provider = try XCTUnwrap(CGDataProvider(data: shortData as CFData))

        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)

        XCTAssertNil(image, "CoreGraphics must refuse a provider shorter than the declared geometry")
    }
}
