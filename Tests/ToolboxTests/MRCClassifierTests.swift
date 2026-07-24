// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import XCTest
import PDFKit
@testable import Toolbox

final class MRCClassifierTests: XCTestCase {
    /// A scan fixture page is exactly one image, no text, no vector paint.
    func testSingleImageScanPageIsSimple() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.greyscaleScanPDF()))
        XCTAssertEqual(MRCClassifier.structure(of: try XCTUnwrap(doc.page(at: 0))), .simpleSingleImage)
    }

    /// A born-digital page has text operators → complex (R2: rasterising it would destroy
    /// selectable text, so the whole document must take the plain gs path).
    func testBornDigitalPageIsComplex() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.bornDigitalPDF()))
        XCTAssertEqual(MRCClassifier.structure(of: try XCTUnwrap(doc.page(at: 0))), .complex)
    }

    /// Structure is about shape, not content — the photo fixture is still one image, no text,
    /// no vector paint, so it must still classify as simple even though its signal profile
    /// (Task 6) will later fail the MRC envelope.
    func testPhotoScanPageIsSimpleSingleImage() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.colourPhotoScanPDF()))
        XCTAssertEqual(MRCClassifier.structure(of: try XCTUnwrap(doc.page(at: 0))), .simpleSingleImage)
    }

    /// An annotation on an otherwise-simple scan page must fail closed to `.complex` — MRC
    /// would clobber the annotation on rasterisation.
    func testAnnotatedPageIsComplex() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.greyscaleScanPDF()))
        let page = try XCTUnwrap(doc.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20),
                                        forType: .text, withProperties: nil)
        page.addAnnotation(annotation)
        XCTAssertEqual(MRCClassifier.structure(of: page), .complex)
    }

    /// Text-class page renders → features inside the eligible envelope. The explicit
    /// moderate-chroma bound guards the fixture-vs-gate margin: the fixture's chromatic ink
    /// counts toward `moderateChromaCoverage`, so a fixture redraw that pushes it near the 0.115
    /// gate must fail here deterministically, not flake in whichever test renders it next.
    func testTextScanPageFeaturesPassVerdict() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.colourTextScanPDF()))
        let page = try XCTUnwrap(doc.page(at: 0))
        let image = try PDFService().render(page, maxDimension: MRCClassifier.renderDimension(for: page))
        let features = try XCTUnwrap(MRCClassifier.features(of: image))
        XCTAssertNil(MRCClassifier.verdict(features: features))
        XCTAssertLessThan(features.moderateChromaCoverage,
                          MRCClassifier.maxModerateChromaCoverage - 0.01,
                          "the text fixture must clear the chroma gate with real margin")
    }

    /// A text page on a pale fine-pattern (guilloche-class) background → declined by the
    /// moderate-chroma gate with its own reason. This is the field-regression fixture: the
    /// pattern's channel delta sits below `colourCoverage`'s > 40 test, so without the moderate
    /// gate the page is eligible and MRC blurs the pattern into the background layer.
    func testPalePatternPageDeclinedAsChromaPattern() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.palePatternTextScanPDF()))
        let page = try XCTUnwrap(doc.page(at: 0))
        let image = try PDFService().render(page, maxDimension: MRCClassifier.renderDimension(for: page))
        let features = try XCTUnwrap(MRCClassifier.features(of: image))
        XCTAssertEqual(MRCClassifier.verdict(features: features), .chromaPattern)
        XCTAssertGreaterThan(features.moderateChromaCoverage,
                             MRCClassifier.maxModerateChromaCoverage,
                             "the pattern must trip the moderate-chroma gate specifically")
        XCTAssertLessThanOrEqual(features.colourCoverage, MRCClassifier.maxColourCoverage,
                                 "discriminating: the old strong-colour gate alone would admit it")
    }

    /// Photo-class page → declined (.notTextDominant).
    func testPhotoScanPageFailsVerdict() throws {
        let doc = try XCTUnwrap(PDFDocument(url: try Fixtures.colourPhotoScanPDF()))
        let page = try XCTUnwrap(doc.page(at: 0))
        let image = try PDFService().render(page, maxDimension: MRCClassifier.renderDimension(for: page))
        let features = try XCTUnwrap(MRCClassifier.features(of: image))
        XCTAssertEqual(MRCClassifier.verdict(features: features), .notTextDominant)
    }

    /// C1 regression: an odd-width image (row padding present) must measure the same ink
    /// coverage as the same content at an even width — padding bytes must never be sampled.
    func testOddWidthBufferDoesNotPolluteInkCoverage() throws {
        let even = try XCTUnwrap(MRCClassifier.features(of: try syntheticTextImage(width: 400, height: 300)))
        let odd = try XCTUnwrap(MRCClassifier.features(of: try syntheticTextImage(width: 401, height: 300)))
        XCTAssertEqual(even.inkCoverage, odd.inkCoverage, accuracy: 0.01)
    }

    /// A deterministic short-bar text-like grid drawn into an RGBA context of exactly
    /// `width`×`height`. At an odd width CoreGraphics pads each row, so `bytesPerRow != width * 4`
    /// — the padded buffer the C1 regression needs. The ink *fraction* is width-independent (the
    /// bar grid has a fixed period and tiles the full width), while the fine horizontal structure
    /// makes a row-stride bug (reading `y * width * 4` instead of `y * bytesPerRow`) shear the
    /// read and change the measured coverage — so a broken walk cannot pass the regression.
    private func syntheticTextImage(width: Int, height: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.35, alpha: 1))
        var y = 12
        while y + 12 <= height {                       // bar rows: 12 px tall, 24 px pitch
            var x = 8
            while x + 20 <= width {                     // bars: 20 px wide, 32 px pitch
                ctx.fill(CGRect(x: x, y: y, width: 20, height: 12))
                x += 32
            }
            y += 24
        }
        return try XCTUnwrap(ctx.makeImage())
    }
}
