// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class MRCComposerTests: XCTestCase {

    // MARK: Fixtures

    /// A solid-colour DeviceRGB JPEG, ImageIO-encoded exactly as the real pipeline produces the
    /// background/foreground layers.
    private func solidJPEG(width: Int = 8, height: Int = 8,
                           red: CGFloat, green: CGFloat, blue: CGFloat) -> MRCComposer.JPEGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let buffer = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return MRCComposer.JPEGImage(data: buffer as Data, width: width, height: height)
    }

    /// A bilevel CCITT mask: black ink over the left half, white paper on the right. The vertical
    /// split lets the polarity test read left-vs-right without worrying about the image/PDF
    /// top-bottom flip.
    private func halfInkMask(width: Int = 64, height: Int = 64) -> CCITTEncoder.Encoded {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)                                   // white paper
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)                                   // black ink, left half
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return CCITTEncoder.encode(context.makeImage()!)!
    }

    private func mrcPage() -> MRCComposer.Page {
        MRCComposer.Page(
            content: .mrc(background: solidJPEG(red: 1, green: 1, blue: 1),
                          foreground: solidJPEG(red: 1, green: 0, blue: 0),
                          mask: halfInkMask()),
            size: CGSize(width: 612, height: 792))
    }

    private func jpegPage() -> MRCComposer.Page {
        MRCComposer.Page(
            content: .jpeg(solidJPEG(red: 0.2, green: 0.4, blue: 0.8)),
            size: CGSize(width: 612, height: 792))
    }

    /// Mean R/G/B over a rectangular region of a rendered RGBA page, each 0…1.
    private func meanColour(_ image: CGImage, region: CGRect) -> (r: Double, g: Double, b: Double) {
        let data = image.dataProvider!.data!
        let ptr = CFDataGetBytePtr(data)!
        let length = CFDataGetLength(data)
        let bpp = image.bitsPerPixel / 8
        var sr = 0.0, sg = 0.0, sb = 0.0, count = 0.0
        let minX = max(0, Int(region.minX)), maxX = min(image.width, Int(region.maxX))
        let minY = max(0, Int(region.minY)), maxY = min(image.height, Int(region.maxY))
        for y in minY..<maxY {
            for x in minX..<maxX {
                let o = y * image.bytesPerRow + x * bpp
                guard o + 2 < length else { continue }
                sr += Double(ptr[o]); sg += Double(ptr[o + 1]); sb += Double(ptr[o + 2])
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (sr / count / 255, sg / count / 255, sb / count / 255)
    }

    // MARK: Invariants

    /// I1: every /SMask stream's ColorSpace is the literal /DeviceGray. CoreGraphics silently
    /// renders ghost text on any other space (measured in the spike) — THE invariant.
    func testSoftMaskColorSpaceIsDeviceGray() throws {
        let data = try MRCComposer.compose(pages: [mrcPage()])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("/ColorSpace /DeviceGray"))
        XCTAssertFalse(text.contains("ICCBased"))
        XCTAssertNotNil(PDFDocument(data: data))
    }

    /// I2: the composer never emits `/Rotate`. Layers arrive upright (`PDFService.render` bakes the
    /// source `/Rotate` into the pixels), so the composed page must carry no `/Rotate` at all —
    /// re-stamping it would turn an already-upright page a second time (the double-rotation bug).
    func testComposerNeverEmitsRotate() throws {
        let data = try MRCComposer.compose(pages: [mrcPage(), jpegPage()])
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.page(at: 0)?.rotation, 0)
        XCTAssertEqual(doc.page(at: 1)?.rotation, 0)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("/Rotate"), "the composer must never write a /Rotate entry")
    }

    /// I3: MediaBox preserved; mask/layer pixel dimensions match what was passed in.
    func testGeometryPreserved() throws {
        let a4 = CGSize(width: 595.276, height: 841.89)
        let page = MRCComposer.Page(
            content: .mrc(background: solidJPEG(width: 8, height: 8, red: 1, green: 1, blue: 1),
                          foreground: solidJPEG(width: 8, height: 8, red: 1, green: 0, blue: 0),
                          mask: halfInkMask(width: 64, height: 64)),
            size: a4)
        let data = try MRCComposer.compose(pages: [page])

        let doc = try XCTUnwrap(PDFDocument(data: data))
        let bounds = try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, a4.width, accuracy: 0.001)
        XCTAssertEqual(bounds.height, a4.height, accuracy: 0.001)

        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("/Width 64 /Height 64"), "mask dimensions must match input")
        XCTAssertTrue(text.contains("/Width 8 /Height 8"), "layer dimensions must match input")
    }

    /// Mixed documents interleave both page kinds in order, each rendering non-blank.
    func testMixedPageKindsCompose() throws {
        let data = try MRCComposer.compose(pages: [jpegPage(), mrcPage(), jpegPage()])
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.pageCount, 3)
        for index in 0..<3 {
            let page = try XCTUnwrap(doc.page(at: index))
            let rendered = try PDFService().render(page, maxDimension: 200)
            let mean = meanColour(rendered, region: CGRect(x: 0, y: 0,
                                                           width: rendered.width, height: rendered.height))
            XCTAssertGreaterThan(mean.r + mean.g + mean.b, 0.05, "page \(index) rendered blank")
        }
    }

    /// Degenerate size throws, never clamps (BilevelPDFComposer's rule).
    func testInvalidPageSizeThrows() throws {
        let badSizes: [CGSize] = [
            CGSize(width: 0, height: 800),
            CGSize(width: 600, height: 0),
            CGSize(width: -5, height: 800),
            CGSize(width: CGFloat.infinity, height: 800),
            CGSize(width: CGFloat.nan, height: 800),
        ]
        for size in badSizes {
            XCTAssertThrowsError(
                try MRCComposer.compose(pages: [MRCComposer.Page(
                    content: .jpeg(solidJPEG(red: 1, green: 0, blue: 0)), size: size)]),
                "size \(size) must be rejected, not clamped")
        }
    }

    func testEmptyPagesThrows() throws {
        XCTAssertThrowsError(try MRCComposer.compose(pages: []))
    }

    /// The mask-polarity check — the only trustworthy way to pin CCITT `/Decode` (spike proved
    /// polarity is empirical, not theoretical). Foreground is solid red over a left-half-ink
    /// mask; after rendering, red must appear ONLY in the masked (ink) half. Passes with
    /// `/Decode [1 0]`; would fail (red on the wrong half) with `[0 1]`.
    func testMaskPolarity() throws {
        let data = try MRCComposer.compose(pages: [mrcPage()])
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(doc.page(at: 0))
        let rendered = try PDFService().render(page, maxDimension: 400)

        let w = rendered.width, h = rendered.height
        let left = meanColour(rendered, region: CGRect(x: 0, y: 0, width: w / 2, height: h))
        let right = meanColour(rendered, region: CGRect(x: w / 2, y: 0, width: w / 2, height: h))

        // Left = ink half → foreground red opaque: strongly red (R high, G/B low).
        XCTAssertGreaterThan(left.r, 0.5, "ink half should be red (R=\(left.r))")
        XCTAssertLessThan(left.g, 0.4, "ink half should be red, not white (G=\(left.g))")
        // Right = paper half → background white shows through: not red (G high).
        XCTAssertGreaterThan(right.g, 0.6, "paper half should show white background (G=\(right.g))")
    }
}
