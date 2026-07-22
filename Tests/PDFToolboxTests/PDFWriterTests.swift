// PDF Toolbox
// Copyright (C) 2026 PDF Toolbox authors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import PDFKit
import XCTest
@testable import PDFToolbox

final class PDFWriterTests: XCTestCase {

    private let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    // MARK: - Coordinate transform (pure functions PDFWriter owns)

    func testDisplayedSizeSwapsAt90And270() {
        XCTAssertEqual(PDFWriter.displayedSize(mediaBox: letter, rotation: 0), CGSize(width: 612, height: 792))
        XCTAssertEqual(PDFWriter.displayedSize(mediaBox: letter, rotation: 180), CGSize(width: 612, height: 792))
        XCTAssertEqual(PDFWriter.displayedSize(mediaBox: letter, rotation: 90), CGSize(width: 792, height: 612))
        XCTAssertEqual(PDFWriter.displayedSize(mediaBox: letter, rotation: 270), CGSize(width: 792, height: 612))
    }

    func testUserPointInverseRotationConcrete() {
        let p = CGPoint(x: 100, y: 200)
        assertPoint(PDFWriter.userPoint(displayed: p, mediaBox: letter, rotation: 0),   CGPoint(x: 100, y: 200))
        assertPoint(PDFWriter.userPoint(displayed: p, mediaBox: letter, rotation: 90),  CGPoint(x: 412, y: 100))
        assertPoint(PDFWriter.userPoint(displayed: p, mediaBox: letter, rotation: 180), CGPoint(x: 512, y: 592))
        assertPoint(PDFWriter.userPoint(displayed: p, mediaBox: letter, rotation: 270), CGPoint(x: 200, y: 692))
    }

    /// The displayed rectangle's corners must map bijectively onto the media rectangle — a
    /// direction-independent proof the rotation maths is a true rotation, not a wrong model.
    func testRotationCornersCoverMediaBox() {
        for rotation in [0, 90, 180, 270] {
            let d = PDFWriter.displayedSize(mediaBox: letter, rotation: rotation)
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: d.width, y: 0),
                           CGPoint(x: d.width, y: d.height), CGPoint(x: 0, y: d.height)]
            let mapped = corners.map { PDFWriter.userPoint(displayed: $0, mediaBox: letter, rotation: rotation) }
            let xs = mapped.map(\.x), ys = mapped.map(\.y)
            XCTAssertEqual(xs.min()!, 0, accuracy: 0.01, "rotation \(rotation)")
            XCTAssertEqual(xs.max()!, 612, accuracy: 0.01, "rotation \(rotation)")
            XCTAssertEqual(ys.min()!, 0, accuracy: 0.01, "rotation \(rotation)")
            XCTAssertEqual(ys.max()!, 792, accuracy: 0.01, "rotation \(rotation)")
        }
    }

    func testMediaBoxOriginOffsetApplied() {
        let shifted = CGRect(x: 50, y: 30, width: 612, height: 792)
        assertPoint(PDFWriter.userPoint(displayed: CGPoint(x: 0, y: 0), mediaBox: shifted, rotation: 0),
                    CGPoint(x: 50, y: 30))
    }

    // MARK: - Incremental-update invariants

    func testOriginalBytesAreVerbatimPrefixOfOutput() throws {
        let input = try Fixtures.imagePDF()
        let output = try sibling(of: input, "prefix.pdf")
        let before = try Data(contentsOf: input)

        try PDFWriter().appendTextLayer(
            to: input, output: output,
            pageText: [0: [PositionedText(text: "HELLO", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))]],
            geometry: [0: PageGeometry(mediaBox: letter, rotation: 0)])

        let after = try Data(contentsOf: output)
        XCTAssertGreaterThan(after.count, before.count, "an incremental update only grows the file")
        XCTAssertEqual(after.prefix(before.count), before,
                       "the original bytes (incl. every image XObject) must be a verbatim prefix")
    }

    func testAppendedTextIsExtractableAndPageCountPreserved() throws {
        let input = try Fixtures.imagePDF()
        let output = try sibling(of: input, "extract.pdf")

        try PDFWriter().appendTextLayer(
            to: input, output: output,
            pageText: [0: [PositionedText(text: "HELLO", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))]],
            geometry: [0: PageGeometry(mediaBox: letter, rotation: 0)])

        let inDoc = try XCTUnwrap(PDFDocument(url: input))
        let outDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(outDoc.pageCount, inDoc.pageCount)
        let text = outDoc.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("HELLO"), "expected the invisible layer to be extractable, got: \(text.debugDescription)")
    }

    /// The output re-opens, page count matches, sample pages render non-blank (image still there).
    func testOutputPassesValidator() throws {
        let input = try Fixtures.imagePDF()
        let output = try sibling(of: input, "valid.pdf")
        try PDFWriter().appendTextLayer(
            to: input, output: output,
            pageText: [0: [PositionedText(text: "HELLO", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))]],
            geometry: [0: PageGeometry(mediaBox: letter, rotation: 0)])
        XCTAssertTrue(try OutputValidator().validate(input: input, output: output))
    }

    /// End-to-end offset/scale sanity on the un-rotated path: PDFKit must report the first glyph
    /// near the user-space point the transform computed (catches a gross offset or scale error
    /// that mere extractability would miss).
    func testZeroDegreeGlyphLandsAtMappedLocation() throws {
        let input = try Fixtures.imagePDF()
        let output = try sibling(of: input, "placed.pdf")
        let box = PositionedText(text: "MARK", boundingBox: CGRect(x: 0.2, y: 0.6, width: 0.2, height: 0.04))
        try PDFWriter().appendTextLayer(
            to: input, output: output,
            pageText: [0: [box]], geometry: [0: PageGeometry(mediaBox: letter, rotation: 0)])

        let doc = try XCTUnwrap(PDFDocument(url: output))
        let page = try XCTUnwrap(doc.page(at: 0))
        let expected = PDFWriter.userPoint(displayed: CGPoint(x: 0.2 * 612, y: 0.6 * 792),
                                           mediaBox: letter, rotation: 0)          // (122.4, 475.2)
        let bounds = page.characterBounds(at: 0)
        XCTAssertEqual(bounds.minX, expected.x, accuracy: 40, "glyph X should sit near the mapped origin")
        XCTAssertEqual(bounds.minY, expected.y, accuracy: 60, "glyph Y should sit near the mapped origin")
    }

    /// The whole pipeline runs on a `/Rotate 90` page without corrupting it, and the layer stays
    /// extractable (the transform's rotation maths is proven separately by the pure-function tests).
    func testRotatedPageAppendIsExtractable() throws {
        let base = try Fixtures.imagePDF()
        let rotatedDoc = try XCTUnwrap(PDFDocument(url: base))
        rotatedDoc.page(at: 0)?.rotation = 90
        let rotated = try sibling(of: base, "rotated.pdf")
        XCTAssertTrue(rotatedDoc.write(to: rotated))

        let output = try sibling(of: base, "rotated-ocr.pdf")
        try PDFWriter().appendTextLayer(
            to: rotated, output: output,
            pageText: [0: [PositionedText(text: "SIDEWAYS", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.04))]],
            geometry: [0: PageGeometry(mediaBox: letter, rotation: 90)])

        let outDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(outDoc.pageCount, 1)
        XCTAssertTrue((outDoc.page(at: 0)?.string ?? "").contains("SIDEWAYS"))
        // The original rotated file is still the verbatim prefix.
        let before = try Data(contentsOf: rotated)
        let after = try Data(contentsOf: output)
        XCTAssertEqual(after.prefix(before.count), before)
    }

    // MARK: - helpers

    private func assertPoint(_ a: CGPoint, _ b: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.01, file: file, line: line)
    }

    private func sibling(of url: URL, _ name: String) throws -> URL {
        url.deletingLastPathComponent().appendingPathComponent(name)
    }
}
